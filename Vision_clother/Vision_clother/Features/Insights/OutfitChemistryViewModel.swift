//
//  OutfitChemistryViewModel.swift
//  Vision_clother
//
//  Analytics & Insights — "Chemistry" sub-tab. Same shape as
//  `TasteInsightsViewModel`: the combo-level color-harmony/style-coherence
//  affinities are read straight off the unified `AttributePreferenceProfile`
//  (via `WardrobeRepository.fetchFeedbackHistory()`), joined with the raw
//  `SwipeCombinationEvent` snapshots the view passes in.
//

import Foundation
import Observation

@Observable
@MainActor
final class OutfitChemistryViewModel {
    private(set) var snapshot: OutfitChemistrySnapshot?

    private var recomputeTask: Task<Void, Never>?

    func recompute(combinations: [RatedCombinationSnapshot], repository: WardrobeRepository) {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            guard let self else { return }
            let history = (try? await repository.fetchFeedbackHistory()) ?? FeedbackHistory()
            guard !Task.isCancelled else { return }
            let snap = OutfitChemistryAggregator.build(profile: history.attributeProfile, combinations: combinations)
            self.snapshot = snap
            AppLog.info(.viewModel, "OutfitChemistryViewModel.recompute: colorRows=\(snap.colorHarmonyRows.count) styleRows=\(snap.styleCoherenceRows.count) hasSignal=\(snap.hasSignal)")
        }
    }
}
