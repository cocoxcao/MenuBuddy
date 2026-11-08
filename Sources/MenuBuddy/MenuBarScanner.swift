import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// Where an item's picture comes from.
enum IconSource: Hashable {
    case file(String)    // an app bundle: its app icon
    case symbol(String)  // an SF Symbol on a light tile (Apple's own items share one process)
    case generic
}

/// One icon in the menu bar, owned by some other app.
struct MenuBarEntry {
    let id: String             // this scan only ("pid:index")
    let key: String            // stable across launches: owner app + which of its icons
    let name: String
    let frame: CGRect          // screen coordinates, top-left origin (Accessibility space)
    let element: AXUIElement
    let icon: IconSource
    let appURL: URL?
}

/// Reads other apps' menu bar icons through Accessibility (`AXExtrasMenuBar`) and clicks them.
enum MenuBarScanner {
    static func scan(includeSystem: Bool, onlyHidden: Bool) -> [MenuBarEntry] {
        guard AXIsProcessTrusted() else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let notchRight = notchRightEdge()
        var found: [MenuBarEntry] = []

        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            let isApple = (app.bundleIdentifier ?? "").hasPrefix("com.apple.")
            if isApple && !includeSystem { continue }
            let items = extras(of: app.processIdentifier)
            if items.isEmpty { continue }
            let owner = Owner(app)
            var usedKeys = Set<String>()

            for (index, element) in items.enumerated() {
                guard let frame = frame(of: element), frame.width > 1, frame.height > 1 else { continue }
                if onlyHidden && !isHidden(frame, notchRight: notchRight) { continue }
                let label = text(of: element)
                var name = owner.name
                var icon = owner.icon
                if isApple {
                    name = label ?? owner.name
                    icon = .symbol(symbol(for: label ?? owner.name))
                } else if items.count > 1, let label, label.caseInsensitiveCompare(owner.name) != .orderedSame {
                    name = "\(owner.name) – \(label)"
                }
                var key = owner.ident
                if isApple || items.count > 1 { key += "#" + (label ?? String(index)) }
                while usedKeys.contains(key) { key += "+" }
                usedKeys.insert(key)
                found.append(MenuBarEntry(id: "\(app.processIdentifier):\(index)", key: key, name: name, frame: frame,
                                          element: element, icon: icon, appURL: owner.url))
            }
        }
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Opens the item's menu, as if it had been clicked. Runs off the main thread: the call can
    /// wait while the other app shows its menu.
    static func press(_ entry: MenuBarEntry, fallback: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            AXUIElementSetMessagingTimeout(entry.element, 0.5)
            var result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
            if result == .actionUnsupported || result == .failure {
                result = AXUIElementPerformAction(entry.element, "AXShowMenu" as CFString)
            }
            // .cannotComplete usually means the menu is open and the app is busy tracking it.
            if result != .success && result != .cannotComplete {
                DispatchQueue.main.async(execute: fallback)
            }
        }
    }

    /// Left edge of the menu bar area to the right of the notch, on the built-in display.
    static func notchRightEdge() -> CGFloat? {
        guard #available(macOS 12.0, *), let screen = NSScreen.screens.first,
              let right = screen.auxiliaryTopRightArea else { return nil }
        return right.minX
    }

    static func isHidden(_ frame: CGRect, notchRight: CGFloat?) -> Bool {
        if let notchRight { return frame.minX < notchRight - 1 }
        guard let screen = NSScreen.screens.first else { return false }
        return frame.minX < screen.frame.minX || frame.maxX > screen.frame.maxX
    }

    // MARK: - Accessibility helpers

    private static func extras(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = kids as? [AXUIElement] else { return [] }
        return list
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func text(of element: AXUIElement) -> String? {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let string = value as? String {
                // "Wi‑Fi, connected, 3 bars" → "Wi‑Fi"
                let first = string.split(separator: ",").first.map(String.init) ?? string
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// The app people know: a helper inside Foo.app/Contents/… is shown as Foo.
    private struct Owner {
        let name: String
        let icon: IconSource
        let url: URL?
        /// Stable identity: the app's path, else its bundle id or name.
        var ident: String { url?.path ?? fallbackIdent }
        private let fallbackIdent: String

        init(_ app: NSRunningApplication) {
            fallbackIdent = app.bundleIdentifier ?? app.localizedName ?? "app"
            guard let bundle = app.bundleURL else {
                name = app.localizedName ?? "App"
                icon = .generic
                url = nil
                return
            }
            let path = bundle.path
            if let range = path.range(of: ".app/") {
                let outer = String(path[..<range.lowerBound]) + ".app"
                url = URL(fileURLWithPath: outer)
                name = Owner.displayName(outer)
                icon = .file(outer)
            } else {
                url = bundle
                name = app.localizedName ?? Owner.displayName(path)
                icon = .file(path)
            }
        }

        static func displayName(_ path: String) -> String {
            let shown = FileManager.default.displayName(atPath: path)
            return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
        }
    }

    private static func symbol(for label: String) -> String {
        let l = label.lowercased()
        let table: [(String, String)] = [
            ("wi", "wifi"), ("battery", "battery.75"), ("bluetooth", "antenna.radiowaves.left.and.right"),
            ("sound", "speaker.wave.2.fill"), ("volume", "speaker.wave.2.fill"), ("clock", "clock"),
            ("focus", "moon.fill"), ("control", "switch.2"), ("spotlight", "magnifyingglass"),
            ("siri", "waveform"), ("display", "display"), ("input", "keyboard"), ("keyboard", "keyboard"),
            ("now playing", "play.circle"), ("mirroring", "rectangle.on.rectangle"),
            ("time machine", "clock.arrow.circlepath"), ("user", "person.crop.circle"), ("vpn", "network"),
            ("weather", "cloud.sun"), ("stage", "rectangle.split.3x1"),
        ]
        for (key, symbol) in table where l.contains(key) { return symbol }
        return "circle.grid.2x2"
    }
}

/// Turns icon sources into PNG data URLs for the theme pages (cached).
enum IconRenderer {
    private static var cache: [IconSource: String] = [:]
    private static let lock = NSLock()

    static func dataURL(_ source: IconSource) -> String {
        lock.lock()
        if let hit = cache[source] { lock.unlock(); return hit }
        lock.unlock()
        let url = "data:image/png;base64," + png(image(source)).base64EncodedString()
        lock.lock()
        cache[source] = url
        lock.unlock()
        return url
    }

    static func image(_ source: IconSource) -> NSImage {
        switch source {
        case .file(let path): return NSWorkspace.shared.icon(forFile: path)
        case .symbol(let name): return symbolTile(name)
        case .generic: return NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }

    /// 128 px square, enough to stay sharp when a theme shows the icon at 2x on a Retina screen.
    static func png(_ image: NSImage, px: Int = 128) -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func symbolTile(_ name: String) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 13, yRadius: 13)
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            tile.fill()
            NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
            tile.lineWidth = 1.5
            tile.stroke()
            var config = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            if #available(macOS 12.0, *) {
                config = config.applying(.init(paletteColors: [NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.18, alpha: 1)]))
            }
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}
