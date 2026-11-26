// Renders the Clawd app icon into App/Assets.xcassets/AppIcon.appiconset.
// Usage: swift Scripts/make_icon.swift
import AppKit

let body: [[Int]] = [Array(2...13), [2, 3] + Array(5...10) + [12, 13], Array(0...15), Array(2...13), [3, 5, 10, 12]]
let eyes = [(4, 1), (11, 1)]
let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.18, green: 0.16, blue: 0.15, alpha: 1), ending: NSColor(red: 0.10, green: 0.09, blue: 0.08, alpha: 1))!
        .draw(in: bg, angle: -90)
    let px = rect.width * 0.62 / 16
    let w = px * 16, h = px * 10
    let ox = rect.midX - w / 2, oy = rect.midY + h / 2 - px * 0.5
    NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1).setFill()
    for (r, cs) in body.enumerated() {
        for c in cs { NSRect(x: ox + CGFloat(c) * px, y: oy - CGFloat(r + 1) * 2 * px, width: px + 0.5, height: 2 * px + 0.5).fill() }
    }
    NSColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1).setFill()
    for (c, r) in eyes { NSRect(x: ox + CGFloat(c) * px, y: oy - CGFloat(r + 1) * 2 * px, width: px, height: 2 * px).fill() }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(base * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: out.appendingPathComponent("Contents.json"))
try #"{"info":{"version":1,"author":"xcode"}}"#.write(to: out.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("icon written")
