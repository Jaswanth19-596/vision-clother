//
//  AnalyticsConfidence.swift
//  Vision_clother
//
//  Analytics & Insights — shared confidence banding for every insight that's
//  derived from a sample size (ratings, impressions, wear logs). Thresholds
//  come from `AnalyticsConfigResponse` (server-resolved via
//  `Services/AnalyticsConfigService.swift`), never re-literaled here, per
//  this layer's convention of not hardcoding a number enforced/described
//  elsewhere.
//

import Foundation

enum ConfidenceLevel: String {
    case stillLearning
    case moderate
    case high

    /// User-facing label — spec examples: "Highly Confident", "Moderately
    /// Confident", "Still Learning".
    var label: String {
        switch self {
        case .stillLearning: return "Still Learning"
        case .moderate: return "Moderately Confident"
        case .high: return "Highly Confident"
        }
    }
}

enum AnalyticsConfidence {
    /// `sampleSize` is whatever count backs the specific insight (e.g. total
    /// outfit ratings for Style DNA, logged wears for a wardrobe stat) — the
    /// caller decides what's being counted, this only bands the number.
    static func level(sampleSize: Int, thresholds: AnalyticsConfigResponse) -> ConfidenceLevel {
        if sampleSize >= thresholds.highConfidenceAtRatings { return .high }
        if sampleSize >= thresholds.stillLearningBelowRatings { return .moderate }
        return .stillLearning
    }

    /// "Based on 148 outfit ratings." — the spec's own example phrasing.
    static func sampleSizeCaption(sampleSize: Int, noun: String) -> String {
        "Based on \(sampleSize) \(noun)."
    }
}
