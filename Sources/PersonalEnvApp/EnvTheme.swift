import SwiftUI
import AppKit

enum EnvTheme {
    static let accent = Color.adaptive(
        light: NSColor(red: 0.16, green: 0.40, blue: 0.93, alpha: 1),
        dark: NSColor(red: 0.42, green: 0.63, blue: 1.00, alpha: 1)
    )
    static let accentSoft = Color.adaptive(
        light: NSColor(red: 0.90, green: 0.94, blue: 1.00, alpha: 1),
        dark: NSColor(red: 0.11, green: 0.18, blue: 0.32, alpha: 1)
    )
    static let canvas = Color.adaptive(
        light: NSColor(red: 0.985, green: 0.985, blue: 0.982, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.080, blue: 0.088, alpha: 1)
    )
    static let panel = Color.adaptive(
        light: NSColor(red: 0.997, green: 0.997, blue: 0.995, alpha: 1),
        dark: NSColor(red: 0.105, green: 0.112, blue: 0.122, alpha: 1)
    )
    static let sidebar = Color.adaptive(
        light: NSColor(red: 0.970, green: 0.970, blue: 0.968, alpha: 1),
        dark: NSColor(red: 0.120, green: 0.126, blue: 0.136, alpha: 1)
    )
    static let separator = Color.adaptive(
        light: NSColor(red: 0.840, green: 0.840, blue: 0.835, alpha: 1),
        dark: NSColor(red: 0.265, green: 0.280, blue: 0.300, alpha: 1)
    )
    static let ink = Color.adaptive(
        light: NSColor(red: 0.12, green: 0.115, blue: 0.10, alpha: 1),
        dark: NSColor(red: 0.93, green: 0.95, blue: 0.94, alpha: 1)
    )
    static let muted = Color.adaptive(
        light: NSColor(red: 0.42, green: 0.42, blue: 0.45, alpha: 1),
        dark: NSColor(red: 0.66, green: 0.70, blue: 0.68, alpha: 1)
    )
    static let tableFill = Color.adaptive(
        light: NSColor(red: 0.997, green: 0.997, blue: 0.995, alpha: 1),
        dark: NSColor(red: 0.085, green: 0.105, blue: 0.105, alpha: 1)
    )
    static let green = Color.adaptive(
        light: NSColor(red: 0.18, green: 0.64, blue: 0.37, alpha: 1),
        dark: NSColor(red: 0.39, green: 0.86, blue: 0.57, alpha: 1)
    )
    static let orange = Color.adaptive(
        light: NSColor(red: 0.96, green: 0.47, blue: 0.10, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.64, blue: 0.28, alpha: 1)
    )
    static let red = Color.adaptive(
        light: NSColor(red: 0.82, green: 0.20, blue: 0.22, alpha: 1),
        dark: NSColor(red: 1.00, green: 0.44, blue: 0.46, alpha: 1)
    )
}

private extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? dark : light
        })
    }
}
