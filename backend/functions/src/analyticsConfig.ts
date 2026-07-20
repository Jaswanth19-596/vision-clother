/**
 * Single canonical source for every confidence/unlock threshold the
 * Analytics & Insights feature needs — imported only by
 * `routes/analyticsConfig.ts`, the resolved-numbers readout the iOS client
 * fetches instead of hardcoding its own copy
 * (`Vision_clother/Services/AnalyticsConfigService.swift`). Mirrors the
 * `entitlementLimits.ts` pattern exactly.
 *
 * Unlike `entitlementLimits.ts`, these numbers are not tier-gated — every
 * user sees the same thresholds today (see docs/decisions on Analytics &
 * Insights: advanced sections ship unlocked for all tiers in this pass).
 * If tier-gating is added later, this module is where the split would live.
 */

export interface AnalyticsThresholds {
  /** Sample sizes below this are "Still Learning" for any confidence-scored insight. */
  stillLearningBelowRatings: number;
  /** Sample sizes at/above this are "Highly Confident"; between the two thresholds is "Moderately Confident". */
  highConfidenceAtRatings: number;
  /** Minimum item + outfit ratings combined before Style DNA scores are shown at all. */
  styleDNAMinRatings: number;
  /** Minimum data points (ratings/impressions) in a time range before a Trends comparison is shown. */
  trendsMinDataPoints: number;
  /** Minimum wardrobe items before Wardrobe Insights (utilization/gaps) is shown. */
  wardrobeInsightsMinItems: number;
  /** Minimum logged "Wore this" events before wear-derived stats (most/least worn) are shown. */
  wardrobeInsightsMinWornLogs: number;
}

export const ANALYTICS_THRESHOLDS: AnalyticsThresholds = {
  stillLearningBelowRatings: 5,
  highConfidenceAtRatings: 25,
  styleDNAMinRatings: 15,
  trendsMinDataPoints: 10,
  wardrobeInsightsMinItems: 8,
  wardrobeInsightsMinWornLogs: 5,
};
