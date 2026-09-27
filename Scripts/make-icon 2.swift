#!/usr/bin/env swift
// Draws Hexeon's Master Ball icon and writes AppIcon.icns.
// Vector-drawn with CoreGraphics — no image assets, no dependencies.
//
//   swift Scripts/make-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext

    let d = s * 0.88                       // ball diameter, leaving icon padding
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = d / 2
    let ball = CGRect(x: c.x - r, y: c.y - r, width: d, height: d)

    // Soft contact shadow so the ball sits on light and dark backgrounds alike.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.05,
                  color: color(0, 0, 0, 0.35))
    ctx.setFillColor(color(255, 255, 255))
    ctx.fillEllipse(in: ball)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: ball)
    ctx.clip()

    // Lower half: off-white with a little depth.
    let space = CGColorSpaceCreateDeviceRGB()
    let bottom = CGGradient(colorsSpace: space,
                            colors: [color(255, 255, 255), color(203, 208, 216)] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(bottom, start: CGPoint(x: c.x, y: c.y),
                           end: CGPoint(x: c.x, y: ball.minY), options: [])

    // Upper half: Master Ball purple.
    ctx.saveGState()
    ctx.addRect(CGRect(x: ball.minX, y: c.y, width: d, height: r))
    ctx.clip()
    let top = CGGradient(colorsSpace: space,
                         colors: [color(138, 74, 186), color(72, 30, 110)] as CFArray,
                         locations: [0, 1])!
    ctx.drawLinearGradient(top, start: CGPoint(x: c.x, y: ball.maxY),
                           end: CGPoint(x: c.x, y: c.y), options: [])
    ctx.restoreGState()

    // The two magenta spheres.
    let pinkR = d * 0.115
    for dx in [-d * 0.265, d * 0.265] {
        let rect = CGRect(x: c.x + dx - pinkR, y: c.y + d * 0.215 - pinkR,
                          width: pinkR * 2, height: pinkR * 2)
        ctx.setFillColor(color(232, 62, 124))
        ctx.fillEllipse(in: rect)
        ctx.setFillColor(color(255, 255, 255, 0.35))
        ctx.fillEllipse(in: rect.insetBy(dx: pinkR * 0.45, dy: pinkR * 0.45)
            .offsetBy(dx: -pinkR * 0.18, dy: pinkR * 0.2))
    }

    // The M, drawn as a path so it needs no font and stays crisp when tiny.
    let mw = d * 0.25, mh = d * 0.185
    let mx = c.x - mw / 2, my = c.y + d * 0.125
    let stroke = mh * 0.30
    let m = CGMutablePath()
    m.move(to: CGPoint(x: mx, y: my))
    m.addLine(to: CGPoint(x: mx + stroke * 0.9, y: my))
    m.addLine(to: CGPoint(x: mx + stroke * 0.9, y: my + mh * 0.55))
    m.addLine(to: CGPoint(x: mx + mw / 2, y: my + mh * 0.10))
    m.addLine(to: CGPoint(x: mx + mw - stroke * 0.9, y: my + mh * 0.55))
    m.addLine(to: CGPoint(x: mx + mw - stroke * 0.9, y: my))
    m.addLine(to: CGPoint(x: mx + mw, y: my))
    m.addLine(to: CGPoint(x: mx + mw, y: my + mh))
    m.addLine(to: CGPoint(x: mx + mw * 0.72, y: my + mh))
    m.addLine(to: CGPoint(x: mx + mw / 2, y: my + mh * 0.52))
    m.addLine(to: CGPoint(x: mx + mw * 0.28, y: my + mh))
    m.addLine(to: CGPoint(x: mx, y: my + mh))
    m.closeSubpath()
    ctx.addPath(m)
    ctx.setFillColor(color(255, 255, 255))
    ctx.fillPath()

    // Centre band.
    ctx.setFillColor(color(26, 26, 32))
    ctx.fill(CGRect(x: ball.minX, y: c.y - d * 0.065, width: d, height: d * 0.13))

    // Specular sheen across the top-left.
    ctx.setFillColor(color(255, 255, 255, 0.16))
    ctx.fillEllipse(in: CGRect(x: ball.minX + d * 0.10, y: c.y + d * 0.13,
                               width: d * 0.42, height: d * 0.26))
    ctx.restoreGState()

    // Button, then the outline last so it sits on top of everything.
    let buttonR = d * 0.115
    let button = CGRect(x: c.x - buttonR, y: c.y - buttonR, width: buttonR * 2, height: buttonR * 2)
    ctx.setFillColor(color(26, 26, 32))
    ctx.fillEllipse(in: button.insetBy(dx: -d * 0.028, dy: -d * 0.028))
    ctx.setFillColor(color(248, 249, 251))
    ctx.fillEllipse(in: button)
    ctx.setStrokeColor(color(26, 26, 32))
    ctx.setLineWidth(max(s * 0.004, d * 0.012))
    ctx.strokeEllipse(in: button.insetBy(dx: buttonR * 0.42, dy: buttonR * 0.42))

    ctx.setStrokeColor(color(26, 26, 32))
    ctx.setLineWidth(max(s * 0.008, d * 0.035))
    ctx.strokeEllipse(in: ball.insetBy(dx: d * 0.017, dy: d * 0.017))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// iconutil accepts only these names; anything else makes the whole set invalid.
let names: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
]
for size in sizes {
    let rep = draw(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    for name in names[size] ?? [] {
        try? data.write(to: iconset.appendingPathComponent(name))
    }
}
print("wrote \(iconset.path)")
