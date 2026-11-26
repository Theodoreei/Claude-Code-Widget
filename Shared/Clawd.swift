import SwiftUI

/// Brand-ish palette.
enum Palette {
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)      // #D97757
    static let clayDark = Color(red: 0.70, green: 0.36, blue: 0.25)
    static let ink = Color(red: 0.12, green: 0.11, blue: 0.10)
    static let cream = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let night = Color(red: 0.13, green: 0.12, blue: 0.11)

    static func background(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.17, green: 0.15, blue: 0.14), night], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [cream, Color(red: 0.93, green: 0.90, blue: 0.85)], startPoint: .top, endPoint: .bottom)
    }
}

enum ClawdMood {
    case happy, working, waiting, sleeping

    init(_ state: ActivityState) {
        switch state {
        case .working: self = .working
        case .waiting: self = .waiting
        case .idle: self = .sleeping
        }
    }
}

/// Clawd, the Claude Code mascot, drawn as the same pixel grid the CLI prints.
/// Grid is 16 × 5; each pixel is twice as tall as it is wide (like terminal half-blocks).
struct ClawdShape {
    static let cols = 16
    static let rows = 5
    static let body: [[Int]] = [
        Array(2...13),
        [2, 3] + Array(5...10) + [12, 13],
        Array(0...15),
        Array(2...13),
        [3, 5, 10, 12],
    ]
    static let eyes: [(Int, Int)] = [(4, 1), (11, 1)]
    static let aspect: CGFloat = CGFloat(cols) / CGFloat(rows * 2)   // width / height
}

struct ClawdView: View {
    var mood: ClawdMood = .happy
    var color: Color = Palette.clay
    var eyeColor: Color = Palette.ink
    /// Horizontal eye offset in pixels (-1...1), lets the app animate glances.
    var glance: CGFloat = 0
    var blink: Bool = false

    var body: some View {
        Canvas { ctx, size in
            let px = min(size.width / CGFloat(ClawdShape.cols), size.height / CGFloat(ClawdShape.rows * 2))
            let w = px * CGFloat(ClawdShape.cols), h = px * CGFloat(ClawdShape.rows * 2)
            let ox = (size.width - w) / 2, oy = (size.height - h) / 2
            func rect(_ c: CGFloat, _ r: CGFloat, _ rw: CGFloat = 1, _ rh: CGFloat = 1) -> CGRect {
                CGRect(x: ox + c * px, y: oy + r * 2 * px, width: rw * px + 0.5, height: rh * 2 * px + 0.5)
            }
            var path = Path()
            for (r, cols) in ClawdShape.body.enumerated() {
                for c in cols { path.addRect(rect(CGFloat(c), CGFloat(r))) }
            }
            // fill the eye sockets with body colour, then draw eyes on top
            for (c, r) in ClawdShape.eyes { path.addRect(rect(CGFloat(c), CGFloat(r))) }
            ctx.fill(path, with: .color(color))

            for (c, r) in ClawdShape.eyes {
                let cx = CGFloat(c) + glance * 0.35
                switch (mood, blink) {
                case (.sleeping, _), (_, true):
                    // closed: a thin line low in the socket
                    ctx.fill(Path(rect(cx - 0.15, CGFloat(r) + 0.62, 1.3, 0.16)), with: .color(eyeColor))
                case (.waiting, _):
                    // wide-open, attentive
                    ctx.fill(Path(rect(cx, CGFloat(r) - 0.1, 1, 1.1)), with: .color(eyeColor))
                default:
                    ctx.fill(Path(rect(cx, CGFloat(r), 1, 1)), with: .color(eyeColor))
                }
            }
        }
        .aspectRatio(ClawdShape.aspect, contentMode: .fit)
        .accessibilityLabel("Clawd")
    }
}

/// Clawd plus a small mood accessory (z's, sparkle, speech dots).
struct ClawdBadge: View {
    var mood: ClawdMood
    var body: some View {
        ClawdView(mood: mood)
            .overlay(alignment: .topTrailing) {
                Group {
                    switch mood {
                    case .sleeping: Text("z z").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                    case .working: Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.clay)
                    case .waiting: Image(systemName: "ellipsis.bubble.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    case .happy: EmptyView()
                    }
                }
                .offset(x: 8, y: -9)
            }
    }
}

#if canImport(AppKit)
import AppKit

extension ClawdShape {
    /// Template image for the menu bar.
    static func menuBarImage(height: CGFloat = 14, mood: ClawdMood = .happy) -> NSImage {
        let px = height / CGFloat(rows * 2)
        let size = NSSize(width: px * CGFloat(cols), height: height)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (r, cs) in body.enumerated() {
                for c in cs { NSRect(x: CGFloat(c) * px, y: CGFloat(r) * 2 * px, width: px, height: 2 * px).fill() }
            }
            if mood == .sleeping {
                // closed eyes: fill sockets, cut a thin slit
                for (c, r) in eyes { NSRect(x: CGFloat(c) * px, y: CGFloat(r) * 2 * px, width: px, height: 1.2 * px).fill() }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
#endif
