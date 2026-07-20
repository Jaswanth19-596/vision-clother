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
    private(set) var isLoadingConfig = false

    private let configService: AnalyticsConfigService
    private var configTask: Task<Void, Never>?

    init(configService: AnalyticsConfigService = ServiceFactory.makeAnalyticsConfigService()) {
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

    func recompute(inventory: [WardrobeItem], wornLogEntries: [WornLogEntry]) {
        let wardrobeSnapshot = WardrobeInsightsAggregator.buildSnapshot(
            inventory: inventory,
            wornLogEntries: wornLogEntries,
            thresholds: thresholds
        )
        snapshot = wardrobeSnapshot
        shoppingSnapshot = ShoppingInsightsAggregator.buildSnapshot(
            inventory: inventory,
            wardrobeSnapshot: wardrobeSnapshot
        )
    }
}
