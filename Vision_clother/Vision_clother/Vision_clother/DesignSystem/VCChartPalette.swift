//
//  VCChartPalette.swift
//  Vision_clother
//
//  Shared chart color roles — originally `Features/Profile/ProfileChartPalette.swift`
//  (the Best Pairings confidence bar and Formality Comfort Zone proportion
//  bar/legend), promoted here in Analytics & Insights Phase 6 so Profile and
//  Insights draw from one DesignSystem-level definition instead of Insights
//  depending on a Profile-owned file. Categorical hues and light/dark steps
//  are the validated default palette (dataviz skill) — re-validated via
//  `scripts/validate_palette.js` when this promotion happened: light mode
//  passes lightness/chroma/CVD-separation, WARNs on contrast-vs-surface for
//  2 of the 4 hues (meaning those two need visible direct labels rather than
//  color alone — already this codebase's convention for every chart row);
//  dark mode fully passes. Slot ordering is fixed, never cycled, per that
//  palette's CVD-safety derivation.
//

import SwiftUI

enum VCChartPalette {
    /// Theme-aware color from a validated light/dark hex pair.
    private static func dynamic(light: String, dark: String) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(Color(hex: hex) ?? .gray)
        })
    }

    /// Fixed-order categorical slots (blue, aqua, yellow, ...) — assign by
    /// position, never re-sorted by value, so a series keeps its color if
    /// the underlying ranking changes.
    static let categorical: [Color] = [
        dynamic(light: "#2a78d6", dark: "#3987e5"),
        dynamic(light: "#1baf7a", dark: "#199e70"),
        dynamic(light: "#eda100", dark: "#c98500"),
        dynamic(light: "#4a3aa7", dark: "#9085e9"),
    ]

    /// Single-hue fill for a ranked/magnitude bar — one metric per labeled
    /// row, no legend needed, so one consistent hue reads best.
    static let barFill = dynamic(light: "#2a78d6", dark: "#3987e5")
}
