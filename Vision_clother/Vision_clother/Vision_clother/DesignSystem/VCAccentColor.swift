//
//  VCAccentColor.swift
//  Vision_clother
//
//  The literal brand accent value, for the rare call site that needs a
//  `Color` directly rather than the environment tint (e.g. an avatar glyph
//  tint). Mirrors `AccentColor.colorset` exactly — keep both in sync if the
//  hex pair ever changes. Uses the same `dynamic(light:dark:)` UIColor
//  trait-collection pattern `ProfileChartPalette.swift` already established
//  as this codebase's one dynamic-color idiom.
//

import SwiftUI

enum VCAccentColor {
    private static func dynamic(light: String, dark: String) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(Color(hex: hex) ?? .gray)
        })
    }

    /// Deep oxblood (light) / warm terracotta (dark) — reads as boutique
    /// tailoring/leather goods rather than generic system blue.
    static let brand = dynamic(light: "#6E2B3A", dark: "#E08A6C")
}
