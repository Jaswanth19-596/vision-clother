//
//  TasteInsightsViewModel.swift
//  Vision_clother
//
//  Analytics & Insights — "Taste" sub-tab. Same shape as `StyleViewModel`,
//  but simpler: taste is read straight off the unified
//  `AttributePreferenceProfile` (via the version-cached
//  `WardrobeRepository.fetchFeedbackHistory()`), so there's no closet/wear
//  aggregation and no server-resolved threshold gate — the profile's own
//  `hasSignal` is the only unlock gate.
//

import Foundation
import Observation

@Observable
@MainActor
final class TasteInsightsViewModel {
    private(set) var snapshot: TasteInsightsSnapshot?
    /// Taste vs. closet composition — how well what the user owns matches what
    /// they love, built off the same `AttributePreferenceProfile` plus the live
    /// inventory the view passes in.
    private(set) var alignment: TasteClosetAlignmentSnapshot?

    private var recomputeTask: Task<Void, Never>?

    func recompute(inventory: [WardrobeItem], repository: WardrobeRepository) {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            guard let self else { return }
            let history = (try? await repository.fetchFeedbackHistory()) ?? FeedbackHistory()
            guard !Task.isCancelled else { return }
            let snap = TasteInsightsAggregator.build(profile: history.attributeProfile)
            let align = TasteClosetAlignmentAggregator.build(profile: history.attributeProfile, inventory: inventory)
            self.snapshot = snap
            self.alignment = align
            AppLog.info(.viewModel, "TasteInsightsViewModel.recompute: dims=\(snap.dimensions.count) hasSignal=\(snap.hasSignal) alignment=\(align.alignmentScore) buyMore=\(align.buyMore.count) reconsider=\(align.reconsider.count)")
        }
    }
}
