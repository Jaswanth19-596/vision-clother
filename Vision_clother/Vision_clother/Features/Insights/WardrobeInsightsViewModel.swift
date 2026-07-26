//
//  WardrobeInsightsViewModel.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 8 — Wardrobe sub-tab. Same shape as
//  `OverviewViewModel`: fetches the server-resolved confidence/unlock
//  thresholds and re-runs the pure `Domain/WardrobeInsightsAggregator.swift`
//  computation whenever `WardrobeInsightsView`'s `@Query` inputs change.
//  Phase 9 added `Domain/ShoppingInsightsAggregator.swift`, computed right
//  after since it takes the wardrobe snapshot as input rather than
//  recomputing wear counts/redundancy itself.
//

import Foundation
import Observation

@Observable
@MainActor
final class WardrobeInsightsViewModel {
    private(set) var thresholds: AnalyticsConfigResponse = .conservativeDefault
    private(set) var snapshot: WardrobeInsightsAggregator.WardrobeInsightsSnapshot?
    private(set) var shoppingSnapshot: ShoppingInsightsAggregator.ShoppingInsightsSnapshot?
    private(set) var gapReport: ClosetGapReport?
    /// Learned-taste summary for the shared `TasteCalloutCard`, built from the
    /// same `history.attributeProfile` the taste-aware shopping/gap suggestions
    /// already use — so the card gives those suggestions a visible reason.
    private(set) var tasteSnapshot: TasteInsightsSnapshot?
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
        AppLog.info(.viewModel, "WardrobeInsightsViewModel.loadConfigIfNeeded: fetching analytics config")
        configTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingConfig = false
                self.configTask = nil
            }
            do {
                self.thresholds = try await self.configService.fetchConfig()
                AppLog.info(.viewModel, "WardrobeInsightsViewModel.loadConfigIfNeeded: ok")
            } catch {
                AppLog.notice(.viewModel, "WardrobeInsightsViewModel.loadConfigIfNeeded: failed, using conservative default — \(String(describing: error))")
            }
        }
    }

    func recompute(inventory: [WardrobeItem], wornLogEntries: [WornLogEntry], profile: UserStyleProfile? = nil) {
        let wardrobeSnapshot = WardrobeInsightsAggregator.buildSnapshot(
            inventory: inventory,
            wornLogEntries: wornLogEntries,
            thresholds: thresholds
        )
        snapshot = wardrobeSnapshot

        // Shopping/closet-gap suggestions are taste-aware (Unified Preference
        // Engine, 2026-07-24): fetch the version-cached learned taste — the
        // same `AttributePreferenceProfile` swipes and ratings feed — and pass
        // it to both aggregators so "what to buy" is steered toward the user's
        // own style. Async + cancellable, mirroring `StyleViewModel.recompute`.
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            guard let self else { return }
            let history = (try? await self.repository.fetchFeedbackHistory()) ?? FeedbackHistory()
            guard !Task.isCancelled else { return }

            self.shoppingSnapshot = ShoppingInsightsAggregator.buildSnapshot(
                inventory: inventory,
                wardrobeSnapshot: wardrobeSnapshot,
                attributeProfile: history.attributeProfile
            )
            self.gapReport = ClosetGapAnalyzer.analyze(
                inventory: inventory,
                profile: profile,
                attributeProfile: history.attributeProfile
            )
            self.tasteSnapshot = TasteInsightsAggregator.build(profile: history.attributeProfile)
        }
    }
}
