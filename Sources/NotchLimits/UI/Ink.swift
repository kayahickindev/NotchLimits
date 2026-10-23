import SwiftUI

/// Text ink tokens used throughout the panel. Color never carries meaning on
/// its own here — severity color lives separately in `Ink.color(for:)` and is
/// always paired with text or an icon at the call site.
enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let muted = Color.white.opacity(0.40)

    /// Claude brand coral — the spark logo and active-account accents.
    static let coral = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)

    /// Severity → color mapping shared by MeterBar (bar fill) and any other
    /// view that needs to color-code a severity (e.g. the relogin warning).
    /// Validated ≥3.6:1 contrast on the panel's dark glass background.
    static func color(for severity: Severity) -> Color {
        switch severity {
        case .normal:
            return Color.white.opacity(0.55)
        case .warning:
            return Color(red: 0xFA / 255.0, green: 0xB2 / 255.0, blue: 0x19 / 255.0)
        case .serious:
            return Color(red: 0xEC / 255.0, green: 0x83 / 255.0, blue: 0x5A / 255.0)
        case .critical:
            return Color(red: 0xD0 / 255.0, green: 0x3B / 255.0, blue: 0x3B / 255.0)
        }
    }
}

/// The Claude spark: 8 petals radiating from a shared center point, each
/// tapering from a point at the center to a rounded tip — a native vector
/// mark, no image assets.
struct ClaudeSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let length = min(rect.width, rect.height) / 2
        let petal = petalPath(length: length, width: length * 0.42)

        var combined = Path()
        for i in 0..<8 {
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
            transform = transform.rotated(by: Double(i) * .pi / 4)
            combined.addPath(petal.applying(transform))
        }
        return combined
    }

    /// One ray: a point at the center widening to a rounded tip at `length`.
    private func petalPath(length: CGFloat, width: CGFloat) -> Path {
        let tip = width / 2
        return Path { p in
            p.move(to: .zero)
            p.addQuadCurve(to: CGPoint(x: length - tip, y: -tip), control: CGPoint(x: length * 0.55, y: -tip))
            p.addArc(center: CGPoint(x: length - tip, y: 0), radius: tip, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.55, y: tip))
            p.closeSubpath()
        }
    }
}

/// A hand-drawn OpenAI-style mark: three identical elongated loops sharing a
/// center, rotated 0° / 60° / 120°, which interlock into the six-fold knot
/// the OpenAI glyph reads as. Meant to be STROKED (not filled) so the woven
/// loops stay open and legible at ~16pt — an approximation, no asset, no SF
/// Symbol. Used in a neutral ink for the Codex column header.
struct OpenAIMark: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Narrow, tall loops: narrow enough that the centre stays open
        // rather than filling into a blob, tall enough to reach a rounded
        // lobe out past the hub.
        let loopWidth = size * 0.40
        let loopHeight = size * 0.92
        let loop = CGRect(x: -loopWidth / 2, y: -loopHeight / 2, width: loopWidth, height: loopHeight)

        var combined = Path()
        for i in 0..<3 {
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
            transform = transform.rotated(by: Double(i) * .pi / 3)
            combined.addPath(Path(roundedRect: loop, cornerRadius: loopWidth / 2).applying(transform))
        }
        return combined
    }
}
