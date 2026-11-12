import AppKit

/// Menu → Check for Updates…: when you click it, and once every 2 weeks by itself (Settings can turn that off).
/// It asks GitHub for the latest release's version number; if that's newer, it offers to install it
/// with the same install.sh as the README's install line (checksum and signature checked), into the
/// folder this copy runs from. The script quits MenuBuddy, replaces it and opens the new one.
enum Updater {
    private static let latest = URL(string: "https://api.github.com/repos/cocoxcao/MenuBuddy/releases/latest")!
    private static let releases = URL(string: "https://github.com/cocoxcao/MenuBuddy/releases/latest")!
    private static let installer = "https://raw.githubusercontent.com/cocoxcao/MenuBuddy/main/install.sh"
    /// The update uses install.sh and the zip of that exact release tag, not whatever is on main now.
    private static func pinned(_ tag: String) -> (script: String, base: String)? {
        guard tag.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return ("https://raw.githubusercontent.com/cocoxcao/MenuBuddy/v\(tag)/install.sh",
                "https://github.com/cocoxcao/MenuBuddy/releases/download/v\(tag)")
    }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// "Version 0.4.6 (build 12)" for Settings.
    static var label: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(current) (build \(build))"
    }

    static func check(quiet: Bool = false) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        var request = URLRequest(url: latest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (json?["tag_name"] as? String).map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            DispatchQueue.main.async {
                // The automatic check stays silent unless there is something new.
                if quiet && (tag.map { !isNewer($0, than: current) } ?? true) { return }
                show(latest: tag)
            }
        }.resume()
    }

    /// Every 2 weeks the app also checks by itself (Settings can turn this off). It reads only the
    /// version number, and it says something only when a newer version is out.
    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdateCheck") }
    }
    private static var timer: Timer?
    static func startAutoCheck() {
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in checkIfDue() }
        timer?.tolerance = 3600
    }
    static func checkIfDue() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last >= 14 * 86400 else { return }
        check(quiet: true)
    }

    /// "0.10.0" is newer than "0.9.2": compares the numbers part by part.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func show(latest: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard let latest else {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "MenuBuddy couldn't reach GitHub. Check your internet connection and try again."
            alert.runModal()
            return
        }
        guard isNewer(latest, than: current) else {
            alert.messageText = "You're up to date"
            alert.informativeText = "MenuBuddy \(current) is the latest version."
            alert.runModal()
            return
        }
        alert.messageText = "MenuBuddy \(latest) is available"
        alert.informativeText = "You have \(current). Update now? MenuBuddy quits, installs the new version (its checksum and signature are checked) and opens again. Your settings stay."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "What's New")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(latest)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(releases)
        default: break
        }
    }

    /// Runs install.sh in the background into this copy's folder; it outlives MenuBuddy quitting.
    private static func install(_ tag: String) {
        guard let pin = pinned(tag) else { NSWorkspace.shared.open(releases); return }
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().path
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("menubuddy-update.log").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "curl -fsSL \"$1\" | MENUBUDDY_BASE=\"$4\" MENUBUDDY_DEST=\"$2\" bash > \"$3\" 2>&1",
                             "update", pin.script, folder, log, pin.base]
        do {
            try process.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't start the update"
            alert.informativeText = "Run the install line from the README instead:\ncurl -fsSL \(installer) | bash"
            alert.runModal()
        }
    }
}

import SwiftUI

/// Settings: the switch for the automatic check every 2 weeks.
struct AutoUpdateToggle: View {
    @AppStorage("autoUpdateCheck") private var on = true
    var body: some View { Toggle("Check every 2 weeks", isOn: $on) }
}
