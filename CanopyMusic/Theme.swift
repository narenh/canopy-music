import CanopyMusicCore
import SwiftUI

/// Dark theme derived from album artwork. Same rules as the phone web app (`app.js` `themeFor`).
struct ArtworkTheme: Equatable {
    var base: Color
    var accent: Color

    static let fallback = ArtworkTheme(base: Color(rgb: RGB(20, 20, 20)), accent: Color(rgb: RGB(242, 242, 242)))

    init(base: Color, accent: Color) {
        self.base = base
        self.accent = accent
    }

    init(_ colors: ArtworkColors?) {
        guard let colors, let bg = RGB(hex: colors.background) else { self = .fallback; return }
        var base = bg
        var t = 0.05
        while base.luminance > 0.018, t <= 1 {
            base = bg.mixed(with: .black, by: t)
            t += 0.05
        }
        var best: RGB?
        for hex in [colors.secondary, colors.primary, colors.background] {
            guard let original = RGB(hex: hex) else { continue }
            var c = original
            var t = 0.05
            while c.contrast(with: base) < 4.5, t <= 1 {
                c = original.mixed(with: .white, by: t)
                t += 0.05
            }
            if best == nil || c.saturation > best!.saturation { best = c }
        }
        let accent = (best?.saturation ?? 0) < 0.12 ? RGB(242, 242, 242) : best!
        self.init(base: Color(rgb: base), accent: Color(rgb: accent))
    }
}

struct RGB: Equatable {
    var r, g, b: Double

    static let black = RGB(0, 0, 0)
    static let white = RGB(255, 255, 255)

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
    }

    func mixed(with other: RGB, by t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    var luminance: Double {
        func f(_ c: Double) -> Double { let c = c / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }

    func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var saturation: Double { (max(r, g, b) - min(r, g, b)) / 255 }
}

extension Color {
    init(rgb: RGB) {
        self.init(.sRGB, red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }

    init?(hex: String) {
        guard let rgb = RGB(hex: hex) else { return nil }
        self.init(rgb: rgb)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ArtworkTheme.fallback
}

extension EnvironmentValues {
    var artworkTheme: ArtworkTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
