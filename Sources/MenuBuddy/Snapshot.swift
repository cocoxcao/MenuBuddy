import AppKit
import WebKit

#if DEV_BUILD

/// `MenuBuddy --snapshot <theme> <out.png> [--hot <index>] [--wait <seconds>]`
/// Renders a theme with WebKit (the engine the app uses) and a few running apps' icons, then
/// writes a PNG. A development check, so the window briefly sits on screen almost invisible.
final class SnapshotCLI {
    private let theme: String
    private let output: URL
    private let hot: Int?
    private let wait: Double
    private let view = ThemeView()
    private var window: NSWindow!
    private var evaluated = false

    init(args: [String]) {
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: MenuBuddy --snapshot <theme> <out.png> [--hot <index>] [--wait <s>]\n".utf8))
            exit(2)
        }
        theme = args[0]
        output = URL(fileURLWithPath: args[1])
        hot = args.firstIndex(of: "--hot").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
        wait = args.firstIndex(of: "--wait").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 2.0
    }

    func start() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 20, y: screen.frame.minY + 20, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.84, blue: 0.90, alpha: 1)
        window.alphaValue = 0.02
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = view.webView
        // Keep animations running even when the screen is idle or covered (WebKit pauses them in
        // occluded windows, which froze shots mid-animation). Private API, dev tool only.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if view.webView.responds(to: occlusion) { view.webView.perform(occlusion, with: nil) }
        window.orderFrontRegardless()

        let demo = AppModel.shared.demoJSON
        view.onReady = { [weak self] in self?.view.setApps(demo, message: "Nothing to show.") }
        view.onSize = { [weak self] size in
            guard let self else { return }
            self.window.setContentSize(size)
        }
        view.load(theme: theme)

        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.capture() }
    }

    private func capture() {
        if let hot {
            let js = "(() => { const el = document.querySelectorAll('.app')[\(hot)]; if (!el) return; const r = el.getBoundingClientRect(); Buddy.pointer(r.left + r.width / 2, r.top + r.height / 2); })()"
            view.webView.evaluateJavaScript(js) { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.takeShot() }
            }
        } else {
            takeShot()
        }
    }

    private func takeShot() {
        // MENUBUDDY_EVAL='js expression' prints its value before the shot (debugging aid).
        if let js = ProcessInfo.processInfo.environment["MENUBUDDY_EVAL"], !evaluated {
            evaluated = true
            let pause = Double(ProcessInfo.processInfo.environment["MENUBUDDY_EVAL_WAIT"] ?? "0") ?? 0
            view.webView.evaluateJavaScript(js) { [weak self] value, error in
                print("eval:", value ?? error?.localizedDescription ?? "nil")
                DispatchQueue.main.asyncAfter(deadline: .now() + pause) { self?.takeShot() }
            }
            return
        }
        view.webView.takeSnapshot(with: nil) { [weak self] image, error in
            guard let self else { return }
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("snapshot failed: \(error?.localizedDescription ?? "no image")\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: self.output)
                print("\(self.output.path) \(Int(self.view.contentSize.width))x\(Int(self.view.contentSize.height))")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}
#endif
