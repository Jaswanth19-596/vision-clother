//
//  OverviewViewModel.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 4 — Overview sub-tab. `OverviewView` supplies
//  the raw `@Query`-fetched rows (same "declarative binding, not a Service
//  call" convention `Features/Profile/ProfileView.swift` already
//  established for full-history aggregate stats — see its ProfileViewModel
//  doc comment); this view model owns the two pieces of imperative work:
//  fetching the server-resolved confidence thresholds and re-running the
//  pure `Domain/AnalyticsAggregator.swift` computation whenever the inputs
//  or selected time range change.
//

import Foundation
import Observation

@Observable
@MainActor
final class OverviewViewModel {
    private(set) var thresholds: AnalyticsConfigResponse = .conservativeDefault
    private(set) var snapshot: AnalyticsAggregator.OverviewSnapshot?
    private(set) var isLoadingConfig = false

    private let configService: AnalyticsConfigService
    private var configTask: Task<Void, Never>?

    init(configService: AnalyticsConfigService = ServiceFactory.makeAnalyticsConfigService()) {
        self.configService = configService
    }

    func loadConfigIfNeeded() {
        guard !isLoadingConfig, configTask == nil else { return }
        isLoadingConfig = true
        AppLog.info(.viewModel, "OverviewViewModel.loadConfigIfNeeded: fetching analytics config")
        configTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingConfig = false
                self.configTask = nil
            }
            do {
                self.thresholds = try await self.configService.fetchConfig()
                AppLog.info(.viewModel, "OverviewViewModel.loadConfigIfNeeded: ok")
            } catch {
                AppLog.notice(.viewModel, "OverviewViewModel.loadConfigIfNeeded: failed, using conservative default — \(String(describing: error))")
            }
        }
    }

    func recompute(
        inventory: [WardrobeItem],
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        timeRange: AnalyticsTimeRange
    ) {
        snapshot = AnalyticsAggregator.buildOverview(
            inventory: inventory,
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            timeRange: timeRange
        )
    }

    var ratingConfidence: ConfidenceLevel {
        AnalyticsConfidence.level(sampleSize: snapshot?.ratingSampleSize ?? 0, thresholds: thresholds)
    }
}
