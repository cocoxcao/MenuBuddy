import AppKit
import Combine
import SwiftUI

/// A small floating window beside System Settings with MenuBuddy's icon to drag into the
/// Accessibility list, like other apps do. Closes itself once access is on.
final class AccessHelper {
    static let shared = AccessHelper()

    private var panel: NSPanel?
    private var watch: AnyCancellable?

    func show(model: AppModel) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.title = "Allow MenuBuddy"
            panel.titlebarAppearsTransparent = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: AccessHelperView(model: model))
            self.panel = panel
        }
        watch = model.$trusted.removeDuplicates().sink { [weak self] trusted in
            guard trusted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self?.close() }
        }
        place()
        panel?.orderFrontRegardless()
        // System Settings takes a moment to open; move beside it once it's there.
        for delay in [0.8, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.place() }
        }
    }

    func close() {
        panel?.orderOut(nil)
        watch = nil
    }

    /// To the right of the System Settings window if there's room, else to its left, else the
    /// screen's bottom-right corner.
    private func place() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.minY + 24)
        if let settings = systemSettingsFrame() {
            let right = settings.maxX + 12
            let left = settings.minX - size.width - 12
            let x = right + size.width <= screen.visibleFrame.maxX ? right : (left >= screen.visibleFrame.minX ? left : nil)
            if let x { origin = NSPoint(x: x, y: settings.midY - size.height / 2) }
        }
        panel.setFrameOrigin(origin)
    }

    /// The frontmost System Settings window, in Cocoa screen coordinates.
    private func systemSettingsFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "System Settings" || owner == "System Preferences",
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"], w > 200, h > 200 else { continue }
            let x = bounds["X"] ?? 0, y = bounds["Y"] ?? 0
            return NSRect(x: x, y: primary.frame.maxY - y - h, width: w, height: h)
        }
        return nil
    }
}

private struct AccessHelperView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if model.trusted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("All set!").font(.title3.weight(.semibold))
                Text("MenuBuddy can see your menu bar now.").foregroundStyle(.secondary)
            } else {
                Text("Open **Accessibility** (not Screen Recording) and drag MenuBuddy into the list:")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                DragAppIcon()
                    .frame(width: 96, height: 96)
                    .help("Drag me into the Accessibility list")
                Text("Then switch MenuBuddy on. Already in the list? Remove it with −, then drag it in again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(width: 300, height: 250)
    }
}

/// MenuBuddy's icon; dragging it drags the app itself (its file), which the list accepts.
private struct DragAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAppIconView { DragAppIconView() }
    func updateNSView(_ view: DragAppIconView, context: Context) {}
}

final class DragAppIconView: NSView, NSDraggingSource {
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        tile.fill()
        let dash: [CGFloat] = [6, 4]
        tile.setLineDash(dash, count: 2, phase: 0)
        tile.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        tile.stroke()
        icon.draw(in: bounds.insetBy(dx: 14, dy: 14))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 14, dy: 14), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
}
