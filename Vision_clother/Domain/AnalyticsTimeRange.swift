//
//  AnalyticsTimeRange.swift
//  Vision_clother
//
//  Analytics & Insights — the shared time-range selector every sub-tab
//  (Overview now, Style/Trends/Wardrobe in later phases) filters by, per the
//  Phase 1 plan's "built once, reused everywhere" note. Pure, no I/O —
//  `Features/Insights/TimeRangeSelector.swift` is the SwiftUI wrapper around
//  this enum, kept separate per Domain/CLAUDE.md ("no UIKit/SwiftUI
//  imports").
//

import Foundation

enum AnalyticsTimeRange: String, CaseIterable, Identifiable, Codable {
    case thirtyDays, threeMonths, sixMonths, oneYear, allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thirtyDays: return "30 Days"
        case .threeMonths: return "3 Months"
        case .sixMonths: return "6 Months"
        case .oneYear: return "1 Year"
        case .allTime: return "All Time"
        }
    }

    /// Short form for the segmented control — full `label` is used for
    /// VoiceOver via `.accessibilityLabel`.
    var shortLabel: String {
        switch self {
        case .thirtyDays: return "30D"
        case .threeMonths: return "3M"
        case .sixMonths: return "6M"
        case .oneYear: return "1Y"
        case .allTime: return "All"
        }
    }

    /// `nil` for `.allTime` — there's no fixed-length window to measure
    /// from, so callers that need a concrete start date should treat `nil`
    /// as "the beginning of all locally-known history."
    var days: Int? {
        switch self {
        case .thirtyDays: return 30
        case .threeMonths: return 90
        case .sixMonths: return 182
        case .oneYear: return 365
        case .allTime: return nil
        }
    }

    /// The window this range covers, ending at `now`. `.allTime` starts at
    /// `.distantPast` so a plain `date >= start` filter still includes every
    /// row without a special-cased branch at every call site.
    func currentInterval(now: Date = .now) -> DateInterval {
        let start = days.map { now.addingTimeInterval(-Double($0) * 86400) } ?? .distantPast
        return DateInterval(start: start, end: now)
    }

    /// The immediately-preceding window of the same length, for
    /// current-vs-previous-period comparisons (e.g. Overview's activity
    /// deltas). `nil` for `.allTime` — there is no "previous all-time" to
    /// compare against.
    func previousInterval(now: Date = .now) -> DateInterval? {
        guard let days else { return nil }
        let currentStart = now.addingTimeInterval(-Double(days) * 86400)
        let previousStart = currentStart.addingTimeInterval(-Double(days) * 86400)
        return DateInterval(start: previousStart, end: currentStart)
    }
}
