//
//  StyleViewModel.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 5 — Style sub-tab (Favorite Colors; Style DNA
//  joined the same tab in Phase 10). Unlike `OverviewViewModel`, this needs
//  the learned taste affinity for the "why" insight, so it goes through
//  `WardrobeRepository.fetchFeedbackHistory()` — already version-cached
//  (`Data/WardrobeRepository.swift`) — rather than re-deriving
//  `AttributePreferenceProfile` itself. Phase 10 reuses that same
//  `attributeProfile` for `Domain/StyleDNAScorer.swift`, computed in the
//  same pass.
//

import Foundation
import Observation

@Observable
@MainActor
final class StyleViewModel {
    private(set) var thresholds: AnalyticsConfigResponse = .conservativeDefault
    private(set) var snapshot: ColorInsightsAggregator.StyleColorSnapshot?
    private(set) var styleDNASnapshot: StyleDNAScorer.StyleDNASnapshot?
    private(set) var isLoadingConfig = false

    private let repository: WardrobeRepository
    private let configService: AnalyticsConfigService
    private var configTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?

    init(repository: WardrobeRepository, configService: AnalyticsConfigService = ServiceFactory.makeAnalyticsConfigService()) {
        self.repository = repository
        self.configService = configService
    }

    func loadConfigIfNeeded() {
        guard !isLoadingConfig, configTask == nil else { return }
        isLoadingConfig = true
        AppLog.info(.viewModel, "StyleViewModel.loadConfigIfNeeded: fetching analytics config")
        configTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingConfig = false
                self.configTask = nil
            }
            do {
                self.thresholds = try await self.configService.fetchConfig()
                AppLog.info(.viewModel, "StyleViewModel.loadConfigIfNeeded: ok")
            } catch {
                AppLog.notice(.viewModel, "StyleViewModel.loadConfigIfNeeded: failed, using conservative default — \(String(describing: error))")
            }
        }
    }

    /// `ratingSampleSize` uses the exact same definition
    /// `Domain/AnalyticsAggregator.swift`'s Overview snapshot does
    /// (`itemRatings.count` + detailed `outfitFeedbacks.count`), passed in
    /// by `StyleView` from its own `@Query` results, rather than
    /// approximating it from `FeedbackHistory`'s decay-weighted tallies —
    /// keeps the confidence gating consistent across Insights sub-tabs.
    func recompute(
        inventory: [WardrobeItem],
        savedCombinations: [SavedCombination],
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        ratingSampleSize: Int,
        comboTimeRange: AnalyticsTimeRange
    ) {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            guard let self else { return }
            let history = (try? await self.repository.fetchFeedbackHistory()) ?? FeedbackHistory()
            guard !Task.isCancelled else { return }

            self.snapshot = ColorInsightsAggregator.buildStyleColorSnapshot(
                inventory: inventory,
                savedCombinations: savedCombinations,
                colorVibeAffinity: history.attributeProfile.colorVibeAffinity,
                ratingSampleSize: ratingSampleSize,
                thresholds: self.thresholds,
                comboTimeRange: comboTimeRange
            )

            self.styleDNASnapshot = StyleDNAScorer.buildSnapshot(
                attributeProfile: history.attributeProfile,
                itemRatings: itemRatings,
                outfitFeedbacks: outfitFeedbacks,
                wornLogEntries: wornLogEntries,
                ratingSampleSize: ratingSampleSize,
                thresholds: self.thresholds
            )
        }
    }
}
