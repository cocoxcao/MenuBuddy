import AppKit

let app = NSApplication.shared

#if DEV_BUILD
let arguments = CommandLine.arguments
// Development tools (scripts/shoot.sh, README "Check a theme quickly"); not in release builds.
if arguments.contains("--seasonal-test") {
    app.setActivationPolicy(.accessory)
    SeasonalOverlay.shared.testMode = true
    SeasonalOverlay.shared.fly()
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
