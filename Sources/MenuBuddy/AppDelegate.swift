import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem!
    private let panel = PanelController()
    private var settings: SettingsWindowController?
    private var monitors: [Any] = []
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var idleRefresh: Timer?
    private var appearanceWatch: NSKeyValueObservation?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // New status items land on the left of the others, which is where the notch hides them.
        // Ask for a spot near the clock instead (only until the user drags it somewhere).
        let positionKey = "NSStatusItem Preferred Position MenuBuddy"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(110.0, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "MenuBuddy"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "MenuBuddy"
            appearanceWatch = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateStatusIcon() }
            }
        }
        updateStatusIcon()

        panel.anchorFrame = { [weak self] in self?.statusItem.button?.window?.frame }
        panel.themeView.onReady = { [weak self] in self?.pushApps() }
        panel.themeView.onOpen = { [weak self] id in self?.open(id) }
        panel.themeView.onMove = { [weak self] id, to in self?.model.move(id, onto: to) }
        panel.themeView.onHide = { [weak self] id in self?.model.hide(id) }
        panel.onContextMenu = { [weak self] id in self?.showAppMenu(for: id) }
        panel.themeView.load(theme: model.themeID)

        model.$themeID.dropFirst().sink { [weak self] id in
            guard let self else { return }
            self.panel.hide()
            self.panel.themeView.load(theme: id)
            DispatchQueue.main.async { self.updateStatusIcon() }
        }.store(in: &bag)
        model.$appsJSON.combineLatest(model.$trusted).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pushApps(quiet: self.model.lastChangeWasArrangement)
                self.panel.pointerMoved(to: NSEvent.mouseLocation)
            }
        }.store(in: &bag)

        installMonitors()
        model.refresh(force: true)
        idleRefresh = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            if self?.panel.isShown == false { self?.model.refresh() }
        }
        idleRefresh?.tolerance = 10

        if !model.trusted { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Status item

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = StatusIcon.image(theme: model.themeID, dark: dark)
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if panel.isShown {
            panel.hide()
        } else {
            openPanel()
        }
    }

    private func showMenu() {
        panel.hide()
        let menu = NSMenu()
        if !model.trusted {
            menu.addItem(ClosureMenuItem(title: "Allow Accessibility Access…") { [weak self] in self?.model.requestAccess() })
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refreshAction), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MenuBuddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func showSettingsAction() { showSettings() }
    @objc private func refreshAction() { model.refresh(force: true) }

    private func showSettings() {
        if settings == nil { settings = SettingsWindowController(model: model) }
        settings?.present()
        model.refresh()
    }

    // MARK: - Panel

    private func pushApps(quiet: Bool = false) {
        panel.themeView.setApps(model.appsJSON, message: model.emptyMessage, quiet: quiet)
    }

    /// Right-click on an app in the panel.
    private func showAppMenu(for id: String) {
        guard let entry = model.entry(id: id) else { return }
        let menu = NSMenu()
        let open = ClosureMenuItem(title: "Open “\(entry.name)”") { [weak self] in self?.open(id) }
        let hide = ClosureMenuItem(title: "Hide “\(entry.name)”") { [weak self] in self?.model.hide(id) }
        let front = ClosureMenuItem(title: "Move to Front") { [weak self] in
            guard let self, let first = self.model.visible.first, first.id != id else { return }
            self.model.move(id, onto: first.id)
        }
        let arrange = ClosureMenuItem(title: "Arrange & Unhide Apps…") { [weak self] in
            self?.panel.hide()
            self?.showSettings()
        }
        let reset = ClosureMenuItem(title: "Reset Order") { [weak self] in self?.model.resetOrder() }
        reset.isEnabled = !model.order.isEmpty
        [open, hide, front].forEach(menu.addItem)
        menu.addItem(.separator())
        [arrange, reset].forEach(menu.addItem)
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func openPanel() {
        openTimer?.invalidate()
        openTimer = nil
        model.refresh()
        pushApps()
        panel.show()
        if model.themeID == "christmas" { SeasonalOverlay.shared.count() }
    }

    private func open(_ id: String) {
        panel.hide()
        guard let entry = model.entry(id: id) else { return }
        if model.themeID == "christmas" { SeasonalOverlay.shared.count() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            MenuBarScanner.press(entry) {
                if let url = entry.appURL { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            }
        }
    }

    // MARK: - Pointer

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.pointerMoved() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.pointerMoved(); return e }) { monitors.append(m) }
        // A click anywhere else closes the panel.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.panel.hide()
        }) { monitors.append(m) }
    }

    private func buttonFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func inHotCorner(_ p: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        return p.x >= screen.frame.maxX - 3 && p.y >= screen.frame.maxY - 3
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        if panel.isShown {
            panel.pointerMoved(to: p)
            if keepOpen(p) {
                closeTimer?.invalidate()
                closeTimer = nil
            } else if closeTimer == nil {
                closeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.closeTimer = nil
                    if !self.keepOpen(NSEvent.mouseLocation) { self.panel.hide() }
                }
            }
            return
        }

        let overButton = model.hoverToOpen && (buttonFrame()?.contains(p) ?? false)
        let corner = model.hotCorner && inHotCorner(p)
        guard overButton || corner else {
            openTimer?.invalidate()
            openTimer = nil
            return
        }
        guard openTimer == nil else { return }
        openTimer = Timer.scheduledTimer(withTimeInterval: overButton ? 0.15 : 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.openTimer = nil
            let q = NSEvent.mouseLocation
            let still = (self.model.hoverToOpen && (self.buttonFrame()?.contains(q) ?? false)) || (self.model.hotCorner && self.inHotCorner(q))
            if still && NSEvent.pressedMouseButtons == 0 { self.openPanel() }
        }
    }

    private func keepOpen(_ p: NSPoint) -> Bool {
        if panel.keepOpenZone()?.contains(p) == true { return true }
        if let b = buttonFrame()?.insetBy(dx: -4, dy: -4), b.contains(p) { return true }
        return model.hotCorner && inHotCorner(p)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// The theme's little glyph for the menu bar; dark outlines turn light on a dark menu bar.
enum StatusIcon {
    static func image(theme: String, dark: Bool) -> NSImage {
        let url = Paths.themes.appendingPathComponent("icons/\(theme).svg")
        if var svg = try? String(contentsOf: url, encoding: .utf8) {
            if dark {
                for ink in ["#1F1B2E", "#1f1b2e", "#1A1A1A", "#1a1a1a", "#111418", "#0F172A"] {
                    svg = svg.replacingOccurrences(of: ink, with: "#F2F1F6")
                }
            }
            if let image = NSImage(data: Data(svg.utf8)) {
                image.size = NSSize(width: 19, height: 19)
                return image
            }
        }
        let fallback = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "MenuBuddy") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
