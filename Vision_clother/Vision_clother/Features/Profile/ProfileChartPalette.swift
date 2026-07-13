//
//  ProfileChartPalette.swift
//  Vision_clother
//
//  Shared color roles for the Profile tab's remaining visual accents — the
//  Best Pairings confidence bar and the Formality Comfort Zone proportion
//  bar/legend (most sections became plain-language narrative in the
//  2026-07-13 redesign; see docs/timeline.md). Categorical hues and
//  light/dark steps are the validated default palette (dataviz skill); slot
//  ordering is fixed, never cycled, per that palette's CVD-safety
//  derivation.
//

import SwiftUI

enum ProfileChartPalette {
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

    /// Single-hue fill for the Best Pairings confidence bar — one metric per
    /// labeled row, no legend needed, so one consistent hue reads best.
    static let barFill = dynamic(light: "#2a78d6", dark: "#3987e5")
}
