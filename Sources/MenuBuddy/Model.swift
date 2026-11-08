import AppKit
import ApplicationServices
import Combine

struct ThemeInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Seasonal themes get a "Limited" tag in Settings.
    var limited: Bool? = nil
}

enum Paths {
    /// The theme pages. In development builds, MENUBUDDY_THEMES=/path/to/Resources/Themes edits them
    /// live without rebuilding; release builds only ever load the signed copies inside the app.
    static let themes: URL = {
        #if DEV_BUILD
        if let dev = ProcessInfo.processInfo.environment["MENUBUDDY_THEMES"] {
            return URL(fileURLWithPath: dev, isDirectory: true)
        }
        #endif
        return Bundle.main.resourceURL!.appendingPathComponent("Themes", isDirectory: true)
    }()
}

/// Settings, the current menu bar contents, and the JSON the theme pages get.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private enum Key {
        static let theme = "theme", hover = "hoverToOpen", corner = "hotCorner"
        static let onlyHidden = "onlyHidden", system = "includeSystem"
        static let order = "order", hiddenApps = "hiddenApps"
    }
    private let defaults = UserDefaults.standard

    let themes: [ThemeInfo]

    @Published var themeID: String { didSet { defaults.set(themeID, forKey: Key.theme) } }
    @Published var hoverToOpen: Bool { didSet { defaults.set(hoverToOpen, forKey: Key.hover) } }
    @Published var hotCorner: Bool { didSet { defaults.set(hotCorner, forKey: Key.corner) } }
    @Published var onlyHidden: Bool { didSet { defaults.set(onlyHidden, forKey: Key.onlyHidden); refresh(force: true) } }
    @Published var includeSystem: Bool { didSet { defaults.set(includeSystem, forKey: Key.system); refresh(force: true) } }

    @Published private(set) var trusted = AXIsProcessTrusted()
    /// Every icon found, in menu bar order (hidden ones included).
    @Published private(set) var entries: [MenuBarEntry] = []
    /// The user's arrangement, as entry keys. Apps not in it go after, in menu bar order.
    @Published private(set) var order: [String]
    /// Keys of apps the user hid from MenuBuddy.
    @Published private(set) var hiddenKeys: Set<String>
    /// [{id, name, icon}] of the visible apps, arranged, for Buddy.setApps.
    @Published private(set) var appsJSON = "[]"
    /// True when the latest appsJSON change came from a rearrange or hide (re-render without the
    /// entry animations).
    private(set) var lastChangeWasArrangement = false

    /// All found apps in the user's order, hidden ones included (Settings list).
    var arranged: [MenuBarEntry] {
        var rank: [String: Int] = [:]
        for (i, key) in order.enumerated() where rank[key] == nil { rank[key] = i }
        let known = entries.filter { rank[$0.key] != nil }.sorted { rank[$0.key]! < rank[$1.key]! }
        return known + entries.filter { rank[$0.key] == nil }
    }

    var visible: [MenuBarEntry] { arranged.filter { !hiddenKeys.contains($0.key) } }
    /// A few running apps, so a theme preview has something to show before access is granted.
    private(set) var demoJSON = "[]"

    var emptyMessage: String {
        if !trusted { return "I need Accessibility access to see your menu bar apps. Right-click my icon and choose Settings." }
        if onlyHidden { return "Nothing is hiding behind the notch right now." }
        return "No menu bar apps found."
    }

    var hasNotch: Bool { MenuBarScanner.notchRightEdge() != nil }

    private let queue = DispatchQueue(label: "menubuddy.scan", qos: .userInitiated)
    private var scanning = false
    private var rescanQueued = false
    private var lastScan = Date.distantPast
    private var lastScanLogged = false
    private var demoMode = false
    private var trustTimer: Timer?

    private init() {
        let url = Paths.themes.appendingPathComponent("themes.json")
        let list = (try? JSONDecoder().decode([ThemeInfo].self, from: Data(contentsOf: url))) ?? []
        themes = list.isEmpty ? [ThemeInfo(id: "inchworm", name: "Inchworm")] : list
        let saved = defaults.string(forKey: Key.theme)
        themeID = themes.first { $0.id == saved }?.id ?? themes[0].id
        hoverToOpen = defaults.object(forKey: Key.hover) as? Bool ?? true
        hotCorner = defaults.object(forKey: Key.corner) as? Bool ?? true
        onlyHidden = defaults.object(forKey: Key.onlyHidden) as? Bool ?? false
        includeSystem = defaults.object(forKey: Key.system) as? Bool ?? false
        order = defaults.stringArray(forKey: Key.order) ?? []
        hiddenKeys = Set(defaults.stringArray(forKey: Key.hiddenApps) ?? [])
        demoJSON = Self.makeDemoJSON()
        scheduleTrustCheck()
    }

    /// Polls the Accessibility switch: every 2 s while waiting for the user to turn it on, every
    /// 10 s once it's on (only to notice it being turned off). Tolerance lets macOS batch wake-ups.
    private func scheduleTrustCheck() {
        trustTimer?.invalidate()
        let interval: TimeInterval = trusted ? 10 : 2
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.checkTrust() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    func entry(id: String) -> MenuBarEntry? { entries.first { $0.id == id } }

    /// Demo video: show these apps (ids demo0, demo1…) instead of scanning, with access on, and
    /// keep the order and hidden list in memory only.
    func loadDemo(_ apps: [(name: String, path: String)]) {
        demoMode = true
        trustTimer?.invalidate()
        trusted = true
        order = []
        hiddenKeys = []
        let placeholder = AXUIElementCreateSystemWide()
        entries = apps.enumerated().map { i, app in
            MenuBarEntry(id: "demo\(i)", key: app.path, name: app.name, frame: .zero, element: placeholder,
                         icon: .file(app.path), appURL: URL(fileURLWithPath: app.path))
        }
        rebuild(arrangement: false)
    }

    /// Rescans in the background. Skipped if the last scan is under two seconds old.
    func refresh(force: Bool = false) {
        guard !demoMode else { return }
        guard force || Date().timeIntervalSince(lastScan) > 2 else { return }
        if scanning { rescanQueued = true; return }
        scanning = true
        lastScan = Date()
        let includeSystem = self.includeSystem
        let onlyHidden = self.onlyHidden
        queue.async { [weak self] in
            let found = MenuBarScanner.scan(includeSystem: includeSystem, onlyHidden: onlyHidden)
            for entry in found { _ = IconRenderer.dataURL(entry.icon) } // warm the icon cache off the main thread
            DispatchQueue.main.async {
                guard let self else { return }
                if found.count != self.entries.count || self.lastScanLogged == false {
                    NSLog("MenuBuddy: Accessibility \(AXIsProcessTrusted() ? "on" : "off"), \(found.count) menu bar icons")
                    self.lastScanLogged = true
                }
                self.entries = found
                self.rebuild(arrangement: false)
                self.scanning = false
                if self.rescanQueued { self.rescanQueued = false; self.refresh(force: true) }
            }
        }
    }

    // MARK: - Arranging and hiding

    /// Drag in the panel: `id` takes the place of `targetID`.
    func move(_ id: String, onto targetID: String) {
        guard let moving = entry(id: id), let target = entry(id: targetID) else { return }
        var keys = visible.map(\.key)
        guard let from = keys.firstIndex(of: moving.key), let to = keys.firstIndex(of: target.key), from != to else { return }
        keys.remove(at: from)
        keys.insert(moving.key, at: to)
        // Hidden and not-running apps keep their place in the saved order, after these.
        saveOrder(keys + order.filter { !keys.contains($0) })
    }

    /// Settings list reorder (hidden apps included).
    func moveArranged(from source: IndexSet, to destination: Int) {
        let all = arranged.map(\.key)
        let moving = source.map { all[$0] }
        var keys = all.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        keys.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        saveOrder(keys + order.filter { !keys.contains($0) })
    }

    func hide(_ id: String) {
        guard let entry = entry(id: id) else { return }
        setHidden(entry.key, true)
    }

    func setHidden(_ key: String, _ hidden: Bool) {
        if hidden { hiddenKeys.insert(key) } else { hiddenKeys.remove(key) }
        if !demoMode { defaults.set(Array(hiddenKeys).sorted(), forKey: Key.hiddenApps) }
        rebuild(arrangement: true)
    }

    func showAllHidden() {
        hiddenKeys = []
        defaults.removeObject(forKey: Key.hiddenApps)
        rebuild(arrangement: true)
    }

    func resetOrder() { saveOrder([]) }

    private func saveOrder(_ keys: [String]) {
        order = keys
        if demoMode {
        } else if keys.isEmpty { defaults.removeObject(forKey: Key.order) } else { defaults.set(keys, forKey: Key.order) }
        rebuild(arrangement: true)
    }

    private func rebuild(arrangement: Bool) {
        let json = Self.json(visible.map { ($0.id, $0.name, $0.icon) })
        guard json != appsJSON else { return }
        lastChangeWasArrangement = arrangement
        appsJSON = json
    }

    func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        AccessHelper.shared.show(model: self)
    }

    private func checkTrust() {
        let now = AXIsProcessTrusted()
        if now != trusted {
            NSLog("MenuBuddy: Accessibility access is now \(now ? "on" : "off")")
            trusted = now
            scheduleTrustCheck()
            refresh(force: true)
        }
    }

    static func json(_ items: [(String, String, IconSource)]) -> String {
        let list = items.map { ["id": $0.0, "name": $0.1, "icon": IconRenderer.dataURL($0.2)] }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func makeDemoJSON() -> String {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleURL != nil }
            .prefix(9)
        let items = apps.enumerated().map { (i, app) in
            ("demo\(i)", app.localizedName ?? "App", IconSource.file(app.bundleURL!.path))
        }
        return json(Array(items))
    }
}

/// A JSON string literal for JavaScript.
func jsString(_ s: String?) -> String {
    guard let s else { return "null" }
    guard let data = try? JSONSerialization.data(withJSONObject: [s]),
          let text = String(data: data, encoding: .utf8) else { return "null" }
    return String(text.dropFirst().dropLast())
}
