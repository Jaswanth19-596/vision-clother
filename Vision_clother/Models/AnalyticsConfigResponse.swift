//
//  AnalyticsConfigResponse.swift
//  Vision_clother
//
//  Wire type for `backend/functions/src/routes/analyticsConfig.ts`'s
//  response — Analytics & Insights confidence/unlock thresholds, resolved
//  server-side from `backend/functions/src/analyticsConfig.ts` so nothing in
//  `Domain/AnalyticsConfidence.swift` hardcodes its own copy. Same posture as
//  `EntitlementLimitsResponse.swift`.
//

import Foundation

struct AnalyticsConfigResponse: Codable, Equatable {
    /// Sample sizes below this are "Still Learning" for any confidence-scored insight.
    var stillLearningBelowRatings: Int
    /// Sample sizes at/above this are "Highly Confident"; between the two thresholds is "Moderately Confident".
    var highConfidenceAtRatings: Int
    /// Minimum item + outfit ratings combined before Style DNA scores are shown at all.
    var styleDNAMinRatings: Int
    /// Minimum data points (ratings/impressions) in a time range before a Trends comparison is shown.
    var trendsMinDataPoints: Int
    /// Minimum wardrobe items before Wardrobe Insights (utilization/gaps) is shown.
    var wardrobeInsightsMinItems: Int
    /// Minimum logged "Wore this" events before wear-derived stats (most/least worn) are shown.
    var wardrobeInsightsMinWornLogs: Int

    /// Used before the first successful fetch — mirrors
    /// `backend/functions/src/analyticsConfig.ts`'s `ANALYTICS_THRESHOLDS`
    /// literal. Never enforces anything itself, same posture as
    /// `EntitlementLimitsResponse.conservativeDefault`.
    static let conservativeDefault = AnalyticsConfigResponse(
        stillLearningBelowRatings: 5,
        highConfidenceAtRatings: 25,
        styleDNAMinRatings: 15,
        trendsMinDataPoints: 10,
        wardrobeInsightsMinItems: 8,
        wardrobeInsightsMinWornLogs: 5
    )
}
