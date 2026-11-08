import AppKit
import SwiftUI

let app = NSApplication.shared

#if DEV_BUILD
let arguments = CommandLine.arguments
// Development tools (scripts/shoot.sh, README "Check a theme quickly"); not in release builds.
if arguments.contains("--seasonal-test") {
    app.setActivationPolicy(.accessory)
    SeasonalOverlay.shared.testMode = true
    SeasonalOverlay.shared.fly()
    app.run()
} else if let index = arguments.firstIndex(of: "--settings-snapshot"), arguments.indices.contains(index + 1) {
    // Settings drawn into a PNG with sample Insights (the theme preview, a web view, comes out blank).
    app.setActivationPolicy(.accessory)
    let out = URL(fileURLWithPath: arguments[index + 1])
    Task { @MainActor in
        let view = SettingsView(model: AppModel.shared, insights: Insights(sample: true), showInsights: arguments.contains("--insights")).padding(.top, 18).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
        }
        exit(0)
    }
    app.run()
} else if let index = arguments.firstIndex(of: "--snapshot") {
    let snapshot = SnapshotCLI(args: Array(arguments[(index + 1)...]))
    app.setActivationPolicy(.accessory)
    snapshot.start()
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
#else
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#endif
