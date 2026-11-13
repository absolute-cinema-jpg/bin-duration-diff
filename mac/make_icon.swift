// Draws the app icon and writes mac/AppIcon.icns.
// Run:  xcrun swift mac/make_icon.swift   (build_app.sh does this if the .icns is missing)
//
// Design: two timeline clips; the lower one is shorter, and the missing
// duration is outlined in orange -- "this clip's duration differs".

import AppKit

let size: CGFloat = 1024
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mac")

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body: macOS icon grid -- 824pt rounded square centred in 1024, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x18213A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x2A3A63), color(0x121A2E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint timeline ruler ticks across the top
    ctx.setFillColor(color(0xFFFFFF, 0.16))
    for i in 0..<15 {
        let x = 214 + CGFloat(i) * 42
        let h: CGFloat = i % 5 == 0 ? 46 : 24
        ctx.fill(CGRect(x: x, y: 790 - h, width: 6, height: h))
    }
    ctx.restoreGState()

    func bar(_ r: CGRect, _ top: UInt32, _ bottom: UInt32) {
        let p = CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.35))
        ctx.addPath(p); ctx.setFillColor(color(bottom)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
        // clip "thumbnail" divider near the head of the clip
        ctx.setFillColor(color(0xFFFFFF, 0.28))
        ctx.fill(CGRect(x: r.minX + 96, y: r.minY, width: 6, height: r.height))
        ctx.restoreGState()
    }

    let left: CGFloat = 214, right: CGFloat = 810, short: CGFloat = 610
    bar(CGRect(x: left, y: 520, width: right - left, height: 132), 0x6FA4FF, 0x3A6FE8)   // clip in bin A
    bar(CGRect(x: left, y: 320, width: short - left, height: 132), 0x6FA4FF, 0x3A6FE8)   // shorter clip in bin B

    // The missing duration: dashed orange outline + hatch
    let gap = CGRect(x: short + 22, y: 320, width: right - short - 22, height: 132)
    let gapPath = CGPath(roundedRect: gap, cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.saveGState()
    ctx.addPath(gapPath); ctx.clip()
    ctx.setFillColor(color(0xFF9F40, 0.18)); ctx.fill(gap)
    ctx.setStrokeColor(color(0xFF9F40, 0.45)); ctx.setLineWidth(10)
    var x = gap.minX - gap.height
    while x < gap.maxX {
        ctx.move(to: CGPoint(x: x, y: gap.minY)); ctx.addLine(to: CGPoint(x: x + gap.height, y: gap.maxY))
        x += 34
    }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(gapPath)
    ctx.setStrokeColor(color(0xFFA24A)); ctx.setLineWidth(10); ctx.setLineDash(phase: 0, lengths: [26, 16])
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Orange marker line where the two durations diverge
    ctx.setFillColor(color(0xFFA24A))
    ctx.fill(CGRect(x: short + 6, y: 262, width: 10, height: 432))
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: short + 11 - 26, y: 720)); tri.addLine(to: CGPoint(x: short + 11 + 26, y: 720))
    tri.addLine(to: CGPoint(x: short + 11, y: 688)); tri.closeSubpath()
    ctx.addPath(tri); ctx.fillPath()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / size, y: CGFloat(px) / size)
    drawIcon(ctx)
    g.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: outDir.appendingPathComponent("AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(outDir.path)/AppIcon.icns" : "iconutil failed")
