import SwiftUI

/// A softened spectrum for the live HUD.
///
/// Pure HSB rainbows look like a toy: saturation is pulled back and brightness
/// is tuned per appearance so settled text keeps its contrast against the
/// material. The hue drifts slowly (one full turn every `period` seconds), so
/// the capsule feels alive without competing with the words.
enum RainbowPalette {
    static let period: TimeInterval = 9

    /// 0...1 hue offset for a moment in time.
    static func phase(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
    }

    /// Strokes and bars: light enough to glow on dark, deep enough on light.
    static func accent(hue: Double, scheme: ColorScheme) -> Color {
        Color(
            hue: wrap(hue),
            saturation: scheme == .dark ? 0.55 : 0.68,
            brightness: scheme == .dark ? 1.0 : 0.86
        )
    }

    /// Settled transcript text: readable first, colorful second.
    static func text(hue: Double, scheme: ColorScheme) -> Color {
        Color(
            hue: wrap(hue),
            saturation: scheme == .dark ? 0.42 : 0.72,
            brightness: scheme == .dark ? 1.0 : 0.62
        )
    }

    /// Evenly spaced stops across `span` of the wheel, starting at `phase`.
    static func stops(
        phase: Double,
        span: Double,
        count: Int = 6,
        color: (Double) -> Color
    ) -> [Color] {
        (0..<count).map { i in color(phase + span * Double(i) / Double(max(count - 1, 1))) }
    }

    private static func wrap(_ hue: Double) -> Double {
        let h = hue.truncatingRemainder(dividingBy: 1)
        return h < 0 ? h + 1 : h
    }
}
