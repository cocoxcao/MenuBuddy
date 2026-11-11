// Draws the MenuBuddy app icon ("Hot Corner": rings spreading from the top-right corner, where
// MenuBuddy opens, on a black tile, "Quiet Mark") into an .icns file.
//   swiftc scripts/make-icon.swift -o build/make-icon && build/make-icon Resources/AppIcon.icns
// build.sh runs this only when Resources/AppIcon.icns is missing; delete it to redraw.
import AppKit

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

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
    ctx.addPath(tile); ctx.setFillColor(srgb(0x1A1B1E)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [srgb(0x3A3B40), srgb(0x0D0E10)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    // Rings centred on the top-right corner, fading out as they spread.
    let corner = CGPoint(x: 924, y: 924)
    for (radius, alpha) in [(CGFloat(620), CGFloat(0.10)), (470, 0.16), (335, 0.28), (215, 1.0)] {
        ctx.setFillColor(srgb(0xFFFFFF, alpha))
        ctx.fillEllipse(in: CGRect(x: corner.x - radius, y: corner.y - radius, width: radius * 2, height: radius * 2))
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
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
