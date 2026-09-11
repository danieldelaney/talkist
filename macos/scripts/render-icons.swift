#!/usr/bin/env swift
// Renders crisp retina keycap status icons (template-friendly) into the
// asset catalog. The shape matches the existing artwork: a hollow rounded-
// rect keycap frame with a T (idle), a dot (recording), or three dots
// (transcribing) inside the transparent dish.
import Cocoa
import CoreGraphics

func renderKeycap(size: Int, state: String) -> Data {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("rep") }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let outer = CGRect(x: s * 0.10, y: s * 0.16, width: s * 0.80, height: s * 0.68)
    let outerRadius = s * 0.19
    // Keycap frame: solid rounded rect
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
    ctx.fillPath()
    // Inner dish: transparent cutout
    let inner = outer.insetBy(dx: s * 0.075, dy: s * 0.075)
    let innerRadius = s * 0.13
    ctx.setBlendMode(.clear)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
    ctx.fillPath()
    ctx.setBlendMode(.normal)

    // State marks: solid inside the transparent dish
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let cx = outer.midX, cy = outer.midY

    if state == "idle" {
        // T: crossbar + stem
        let barW = inner.width * 0.66
        let barH = max(1, s * 0.075)
        let barY = inner.maxY - inner.height * 0.10 - barH - s * 0.035
        ctx.fill(CGRect(x: cx - barW / 2, y: barY, width: barW, height: barH))
        let stemW = max(1, s * 0.075)
        let stemH = inner.height * 0.48
        ctx.fill(CGRect(x: cx - stemW / 2, y: barY - stemH, width: stemW, height: stemH))
    } else if state == "recording" {
        let r = s * 0.11
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    } else if state == "transcribing" {
        let r = s * 0.06
        let gap = s * 0.20
        for dx in [-gap, 0, gap] {
            ctx.fillEllipse(in: CGRect(x: cx + dx - r, y: cy - r, width: r * 2, height: r * 2))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let base = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Talkist/Assets.xcassets")

let states: [(name: String, imageset: String)] = [
    ("idle", "StatusIdle.imageset"),
    ("recording", "StatusRecording.imageset"),
    ("transcribing", "StatusTranscribing.imageset"),
]

for (state, imageset) in states {
    let dir = base.appendingPathComponent(imageset)
    for scale in [1, 2, 3] {
        let px = 18 * scale
        let data = renderKeycap(size: px, state: state)
        let file = "tray-\(state)-\(scale)x.png"
        try? data.write(to: dir.appendingPathComponent(file))
    }
}
print("rendered icons into \(base.path)")
