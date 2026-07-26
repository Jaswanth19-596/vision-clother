//
//  TrendsViewModel.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 7 — Trends sub-tab. Same shape as
//  `OverviewViewModel`: fetches the server-resolved confidence/unlock
//  thresholds and re-runs the pure `Domain/TrendsAggregator.swift`
//  computation whenever `TrendsView`'s `@Query` inputs or the selected time
//  range change.
//

import Foundation
import Observation

@Observable
@MainActor
final class TrendsViewModel {
    private(set) var thresholds: AnalyticsConfigResponse = .conservativeDefault
    private(set) var snapshot: TrendsAggregator.TrendsSnapshot?
    /// Learned-taste summary for the shared `TasteCalloutCard` — the "where
    /// your taste sits now" anchor above the time-series charts.
    private(set) var tasteSnapshot: TasteInsightsSnapshot?
    private(set) var isLoadingConfig = false

    private let configService: AnalyticsConfigService
    private var configTask: Task<Void, Never>?
    private var tasteTask: Task<Void, Never>?

    init(configService: AnalyticsConfigService = ServiceFactory.makeAnalyticsConfigService()) {
        self.configService = configService
    }

    /// Fetches the unified taste profile (version-cached) and builds the
    /// callout summary. Repository injected by the view (same pattern as
    /// `WardrobeInsightsView`).
    func refreshTaste(repository: WardrobeRepository) {
        tasteTask?.cancel()
        tasteTask = Task { [weak self] in
            guard let self else { return }
            let history = (try? await repository.fetchFeedbackHistory()) ?? FeedbackHistory()
            guard !Task.isCancelled else { return }
            self.tasteSnapshot = TasteInsightsAggregator.build(profile: history.attributeProfile)
        }
    }

    func loadConfigIfNeeded() {
        guard !isLoadingConfig, configTask == nil else { return }
        isLoadingConfig = true
        AppLog.info(.viewModel, "TrendsViewModel.loadConfigIfNeeded: fetching analytics config")
        configTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingConfig = false
                self.configTask = nil
            }
            do {
                self.thresholds = try await self.configService.fetchConfig()
                AppLog.info(.viewModel, "TrendsViewModel.loadConfigIfNeeded: ok")
            } catch {
                AppLog.notice(.viewModel, "TrendsViewModel.loadConfigIfNeeded: failed, using conservative default — \(String(describing: error))")
            }
        }
    }

    func recompute(
        inventory: [WardrobeItem],
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        savedCombinations: [SavedCombination],
        timeRange: AnalyticsTimeRange
    ) {
        snapshot = TrendsAggregator.buildTrendsSnapshot(
            inventory: inventory,
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            savedCombinations: savedCombinations,
            timeRange: timeRange,
            thresholds: thresholds
        )
    }
}
