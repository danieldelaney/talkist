#!/usr/bin/env swift
import Cocoa
import CoreGraphics

let size = 1024
let s = CGFloat(size)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

// The icon itself is the keycap, not a mark floating on another tile.
let key = CGRect(x: 36, y: 76, width: 952, height: 900)
ctx.addPath(CGPath(roundedRect: key.offsetBy(dx: 0, dy: -40),
                   cornerWidth: 210, cornerHeight: 210, transform: nil))
ctx.setFillColor(CGColor(red: 75/255, green: 82/255, blue: 94/255, alpha: 1))
ctx.fillPath()

let top = CGPath(roundedRect: key, cornerWidth: 210, cornerHeight: 210, transform: nil)
ctx.saveGState()
ctx.addPath(top)
ctx.clip()
let keyGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(red: 57/255, green: 62/255, blue: 72/255, alpha: 1),
    CGColor(red: 34/255, green: 38/255, blue: 45/255, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(keyGradient, start: CGPoint(x: 512, y: key.maxY),
                       end: CGPoint(x: 512, y: key.minY), options: [])
ctx.restoreGState()

ctx.addPath(top)
ctx.setStrokeColor(CGColor(red: 111/255, green: 121/255, blue: 137/255, alpha: 1))
ctx.setLineWidth(16)
ctx.strokePath()

// Same squat geometric T used by the menu-bar icon.
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
let markWidth: CGFloat = 400
let markHeight: CGFloat = 340
let stroke: CGFloat = 80
let markBottom = key.midY - markHeight / 2
ctx.fill(CGRect(x: key.midX - markWidth / 2,
                y: markBottom + markHeight - stroke,
                width: markWidth, height: stroke))
ctx.fill(CGRect(x: key.midX - stroke / 2,
                y: markBottom,
                width: stroke, height: markHeight - stroke))

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Talkist/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("rendered \(out.path)")
