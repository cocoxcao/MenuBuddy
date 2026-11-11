// Draws the MenuBuddy app icon ("Pill": the menu bar icon, a pill with rings spreading from its
// top-right corner, on a black tile, "Quiet Mark") into an .icns file.
//   build/make-icon <out.png> png [blue]   → one 512 px PNG (docs/images/icon.png, icon-blue.png)
//   swiftc scripts/make-icon.swift -o build/make-icon && build/make-icon Resources/AppIcon.icns
// build.sh runs this only when Resources/AppIcon.icns is missing; delete it to redraw.
import AppKit

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

var blue = false   // the brand blue tile for dark pages (docs/images/icon-blue.png)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // The macOS icon grid: an 824-point tile with a 185-point corner radius, a soft shadow below.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    // Shadows ignore the scale above, so they're sized in pixels.
    let k = size / 1024
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: srgb(0x000000, 0.28))
    ctx.addPath(tile); ctx.setFillColor(blue ? srgb(0x2149E6) : srgb(0x1A1B1E)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: (blue ? [srgb(0x5AABFF), srgb(0x2149E6)] : [srgb(0x3A3B40), srgb(0x0D0E10)]) as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    // The pill (the menu bar icon), see-through white, with rings from its top-right corner that
    // stack and fade, and one solid white corner.
    let pill = CGRect(x: 182, y: 362, width: 660, height: 300)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 150, cornerHeight: 150, transform: nil)); ctx.clip()
    ctx.setFillColor(srgb(0xFFFFFF, 0.10)); ctx.fill(pill)
    let corner = CGPoint(x: pill.maxX - 38, y: pill.maxY)
    for (f, alpha) in [(CGFloat(0.80), CGFloat(0.10)), (0.60, 0.16), (0.42, 0.28), (0.25, 1.0)] {
        let radius = pill.width * f
        ctx.setFillColor(srgb(0xFFFFFF, alpha))
        ctx.fillEllipse(in: CGRect(x: corner.x - radius, y: corner.y - radius, width: radius * 2, height: radius * 2))
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon.icns"
if args.count > 2, args[2] == "png" {
    blue = args.count > 3 && args[3] == "blue"
    try! draw(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("Wrote \(out)"); exit(0)
}
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MenuBuddy.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run()
task.waitUntilExit()
print("Wrote \(out)")
