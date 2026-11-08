import AppKit
import WebKit

/// The Christmas Tree theme's seasonal extra: now and then, opening the theme or clicking an app in
/// it plays a short animation with sound. A see-through, click-through window over the whole screen
/// shows the page in Themes/seasonal.dat (kept encoded so it isn't spoiled at a glance; see
/// scripts/seasonal.sh), which posts its sound (a WAV it synthesises) and "done".
final class SeasonalOverlay: NSObject, WKScriptMessageHandler {
    static let shared = SeasonalOverlay()
    static let everyNth = 5
    private static let countKey = "christmasClicks"

    private var window: NSWindow?
    private var sound: NSSound?

    /// `--seasonal-test`: an invisible, silent run that prints what the page sends, then quits.
    var testMode = false
    private var started = Date()

    /// Counts an open of, or a click in, the Christmas theme; every 5th one plays the extra.
    func count() {
        let count = UserDefaults.standard.integer(forKey: Self.countKey) + 1
        UserDefaults.standard.set(count, forKey: Self.countKey)
        if count % Self.everyNth == 0 { fly() }
    }

    func fly() {
        guard window == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakHandler(self), name: "seasonal")
        let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }

        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false
        win.contentView = web
        win.setFrame(screen.frame, display: false)
        if testMode { win.alphaValue = 0.01 }
        win.orderFrontRegardless()
        window = win
        started = Date()

        guard let html = Self.page(Paths.themes) else { finish(); return }
        WebGuard.protect(config.userContentController) {
            web.loadHTMLString(html, baseURL: nil)
        }
        // Safety net in case the page never says it's done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish() }
    }

    /// The decoded page (base64, then bytes XOR "MenuBuddy"), with its fonts put in as data: URLs
    /// since a page loaded from a string can't read files.
    static func page(_ dir: URL) -> String? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("seasonal.dat"), encoding: .utf8),
              var bytes = Data(base64Encoded: text, options: .ignoreUnknownCharacters).map({ [UInt8]($0) }) else { return nil }
        let key = Array("MenuBuddy".utf8)
        for i in bytes.indices { bytes[i] ^= key[i % key.count] }
        var html = String(decoding: bytes, as: UTF8.self)
        let fonts = try! NSRegularExpression(pattern: #"url\(fonts/([A-Za-z0-9-]+\.woff2)\)"#)
        for match in fonts.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let whole = Range(match.range, in: html), let name = Range(match.range(at: 1), in: html),
                  let font = try? Data(contentsOf: dir.appendingPathComponent("fonts/\(html[name])")) else { continue }
            html.replaceSubrange(whole, with: "url(data:font/woff2;base64,\(font.base64EncodedString()))")
        }
        return html
    }

    private func finish() {
        window?.orderOut(nil)
        window = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if testMode {
            let data = (body["wav"] as? String).flatMap { Data(base64Encoded: $0) }
            let playable = data.flatMap { NSSound(data: $0) }.map { String(format: ", plays %.1fs", $0.duration) } ?? ""
            print(String(format: "%.1fs %@", Date().timeIntervalSince(started), type) + (data.map { " (\($0.count) bytes of WAV\(playable))" } ?? ""))
            if type == "done" { exit(0) }
            return
        }
        switch type {
        case "sound":
            if let b64 = body["wav"] as? String, let data = Data(base64Encoded: b64), let s = NSSound(data: data) {
                sound?.stop()
                sound = s
                s.play()
            }
        case "done":
            finish()
        default:
            break
        }
    }
}

/// Keeps WKUserContentController from retaining the overlay.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
