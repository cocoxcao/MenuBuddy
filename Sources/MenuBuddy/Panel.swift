import AppKit
import WebKit

/// Keeps WKUserContentController from retaining its handler forever.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A transparent web view showing one theme page, talking to it through `Buddy` (buddy.js).
final class ThemeView: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private(set) var themeID: String?
    private(set) var ready = false
    private(set) var contentSize = NSSize(width: 360, height: 220)
    /// Fraction of the width that belongs under the menu bar icon.
    private(set) var anchor: CGFloat = 0.5

    var onReady: (() -> Void)?
    var onSize: ((NSSize) -> Void)?
    var onOpen: ((String) -> Void)?
    /// A drag dropped app `id` onto app `to`.
    var onMove: ((_ id: String, _ to: String) -> Void)?
    /// A drag dropped app `id` on the hide zone.
    var onHide: ((String) -> Void)?

    private var pendingApps: (json: String, message: String, quiet: Bool)?
    private var sentApps: (json: String, message: String)?
    /// The offline rules are in place (see WebGuard); until then a load waits here.
    private var guarded = false
    private var queuedTheme: String?

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), configuration: config)
        super.init()
        config.userContentController.add(WeakScriptHandler(self), name: "buddy")
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        webView.allowsMagnification = false
        WebGuard.protect(config.userContentController) { [weak self] in
            guard let self else { return }
            self.guarded = true
            if let theme = self.queuedTheme { self.queuedTheme = nil; self.startLoad(theme) }
        }
    }

    func load(theme: String) {
        guard theme != themeID else { return }
        themeID = theme
        ready = false
        sentApps = nil
        if guarded { startLoad(theme) } else { queuedTheme = theme }
    }

    private func startLoad(_ theme: String) {
        let dir = Paths.themes
        webView.loadFileURL(dir.appendingPathComponent("\(theme).html"), allowingReadAccessTo: dir)
    }

    /// Sends the app list; the page re-renders only when it changed. `quiet` skips the entry
    /// animations (after a rearrange).
    func setApps(_ json: String, message: String, quiet: Bool = false) {
        guard ready else { pendingApps = (json, message, quiet); return }
        if let sent = sentApps, sent.json == json, sent.message == message { return }
        sentApps = (json, message)
        run("Buddy.setApps(\(json), \(jsString(message)), {quiet: \(quiet)})")
    }

    func show() { if ready { run("Buddy.show()") } }
    func pointer(_ p: NSPoint) { if ready { run("Buddy.pointer(\(p.x), \(p.y))") } }
    func leave() { if ready { run("Buddy.leave()") } }
    func down(_ p: NSPoint) { if ready { run("Buddy.down(\(p.x), \(p.y))") } }
    func drag(_ p: NSPoint) { if ready { run("Buddy.drag(\(p.x), \(p.y))") } }
    func up(_ p: NSPoint) { if ready { run("Buddy.up(\(p.x), \(p.y))") } }
    func cancelDrag() { if ready { run("Buddy.cancel()") } }

    /// The app under a point, if any.
    func appID(at p: NSPoint, _ completion: @escaping (String?) -> Void) {
        guard ready else { completion(nil); return }
        webView.evaluateJavaScript("Buddy.idAt(\(p.x), \(p.y))") { value, _ in completion(value as? String) }
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            if let error { NSLog("MenuBuddy JS: \(error.localizedDescription)") }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            if let pending = pendingApps {
                pendingApps = nil
                setApps(pending.json, message: pending.message, quiet: pending.quiet)
            }
            onReady?()
        case "size":
            // Kept to sane bounds whatever the page says: no bigger than a screen, anchor inside it.
            let limit = NSScreen.screens.map(\.frame.size).reduce(NSSize(width: 800, height: 600)) {
                NSSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
            }
            func clamp(_ v: Double?, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
                guard let v, v.isFinite else { return fallback }
                return min(max(v, lo), hi)
            }
            let w = clamp((body["width"] as? NSNumber)?.doubleValue, 40, Double(limit.width), 360)
            let h = clamp((body["height"] as? NSNumber)?.doubleValue, 40, Double(limit.height), 220)
            anchor = CGFloat(clamp((body["anchor"] as? NSNumber)?.doubleValue, 0, 1, 0.5))
            contentSize = NSSize(width: w, height: h)
            onSize?(contentSize)
        case "open":
            if let id = body["id"] as? String { onOpen?(id) }
        case "move":
            if let id = body["id"] as? String, let to = body["to"] as? String { onMove?(id, to) }
        case "hide":
            if let id = body["id"] as? String { onHide?(id) }
        default:
            break
        }
    }
}

/// Borderless, see-through, never takes focus from the app you're in.
final class BuddyPanel: NSPanel {
    var mouseHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown:
            if mouseHandler?(event) == true { return }
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// The drop-down under the menu bar icon.
final class PanelController {
    let themeView = ThemeView()
    let panel: BuddyPanel
    /// The menu bar icon's window frame (the full menu bar height), in screen coordinates.
    var anchorFrame: () -> NSRect? = { nil }
    /// Right-click on an app.
    var onContextMenu: ((String) -> Void)?
    private(set) var isShown = false
    /// The left button went down inside the panel and hasn't come up yet.
    private(set) var dragging = false
    private var revealPending = false

    init() {
        panel = BuddyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = themeView.webView
        panel.mouseHandler = { [weak self] event in self?.handleMouse(event) ?? false }
        themeView.onSize = { [weak self] _ in
            guard let self else { return }
            self.layout()
            if self.revealPending { self.reveal() }
        }
    }

    /// Orders the panel in invisibly, lets the page render (so entry animations start fresh),
    /// and fades it in once the page reports its size.
    func show() {
        isShown = true
        revealPending = true
        panel.alphaValue = 0
        layout()
        panel.orderFrontRegardless()
        themeView.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if let self, self.isShown, self.revealPending { self.reveal() }
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        revealPending = false
        dragging = false
        panel.orderOut(nil)
        themeView.cancelDrag()
        themeView.leave()
    }

    /// Area where the pointer keeps the panel open: the panel, plus the strip of menu bar above it.
    func keepOpenZone() -> NSRect? {
        guard isShown else { return nil }
        var zone = panel.frame.insetBy(dx: -8, dy: -8)
        if let screen = panel.screen { zone = zone.union(NSRect(x: zone.minX, y: zone.maxY, width: zone.width, height: screen.frame.maxY - zone.maxY)) }
        return zone
    }

    func pointerMoved(to screenPoint: NSPoint) {
        guard isShown else { return }
        if panel.frame.contains(screenPoint) { themeView.pointer(local(screenPoint)) } else { themeView.leave() }
    }

    private func reveal() {
        revealPending = false
        layout()
        panel.alphaValue = 1
        pointerMoved(to: NSEvent.mouseLocation)
    }

    private func layout() {
        let size = themeView.contentSize
        let screen = anchorScreen()
        let anchor = anchorFrame() ?? fallbackAnchor(on: screen)
        let top = anchor.minY
        var x = anchor.midX - size.width * themeView.anchor
        x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height), display: true)
    }

    private func anchorScreen() -> NSScreen {
        if let a = anchorFrame(), let s = NSScreen.screens.first(where: { $0.frame.intersects(a) }) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func fallbackAnchor(on screen: NSScreen) -> NSRect {
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        return NSRect(x: screen.frame.maxX - 180, y: screen.frame.maxY - barHeight, width: 30, height: barHeight)
    }

    private func local(_ p: NSPoint) -> NSPoint {
        NSPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
    }

    /// Clicks never reach the web view (the panel isn't key); the page's Buddy.down/drag/up turn
    /// them into open, rearrange or hide. Right-click (or Control-click) asks for the app's menu.
    private func handleMouse(_ event: NSEvent) -> Bool {
        let p = local(NSEvent.mouseLocation)
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.control), .rightMouseDown:
            themeView.appID(at: p) { [weak self] id in
                if let id { self?.onContextMenu?(id) }
            }
        case .leftMouseDown:
            dragging = true
            themeView.down(p)
        case .leftMouseDragged:
            if dragging { themeView.drag(p) }
        case .leftMouseUp:
            if dragging { themeView.up(p) }
            dragging = false
        default:
            break
        }
        return true
    }
}
