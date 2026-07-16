//
//  StyleCheckViewModel.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste, verification tool: lets the user hand the
//  app one arbitrary clothing photo (not a swipe-deck card, not added to the
//  closet) and see whether it matches what the k-means centroids
//  (`Domain/VisualPreferenceProfile.swift`) have learned so far — a manual
//  sanity check that the model is actually learning, not just a swipe
//  counter. Purely ephemeral: the photo is embedded on-device, scored, and
//  discarded — nothing is persisted (no WardrobeItem, no SwipeEvent).
//

import Foundation
import Observation
import os

/// One check's outcome. `.notEnoughData` is distinct from a neutral/mixed
/// score — it fires when `VisualPreferenceState` has no centroids on either
/// side yet, where a "mixed signals" verdict would be misleading (there's no
/// signal at all, not a genuinely balanced one).
enum StyleCheckVerdict: Equatable {
    case matchesStyle
    case notYourStyle
    case mixedSignals
    case notEnoughData
}

struct StyleCheckResult: Equatable {
    let verdict: StyleCheckVerdict
    /// `nil` only for `.notEnoughData`, where there's no centroid to score
    /// against.
    let detail: VisualMatchDetail?
    /// `VisualPreferenceState.calibrationProgress` at check time — surfaced
    /// alongside the verdict so a result from an under-calibrated profile
    /// (some centroids exist, but fewer than the 20-swipe `isTrained`
    /// threshold) reads as "early signal," not a fully-trained conclusion.
    let calibrationProgress: Double
    let isTrained: Bool
}

enum StyleCheckState: Equatable {
    case idle
    case analyzing
    case result(StyleCheckResult)
    case failed(String)
}

@Observable
@MainActor
final class StyleCheckViewModel {
    private(set) var state: StyleCheckState = .idle

    /// Bonus magnitude above which a match reads as a clear like/dislike
    /// rather than noise — a fifth of `VisualPreferenceProfile.maxBonusMagnitude`
    /// (0.3), so a near-full-strength single-centroid match clears it
    /// comfortably while a faint, ambiguous similarity doesn't.
    private static let verdictThreshold = 0.06

    private let repository: WardrobeRepository
    private let embeddingService: ImageEmbeddingService

    init(repository: WardrobeRepository, embeddingService: ImageEmbeddingService) {
        self.repository = repository
        self.embeddingService = embeddingService
    }

    func checkPhoto(_ imageData: Data) async {
        state = .analyzing
        do {
            let embedding = try await embeddingService.embedding(for: imageData)
            let visualState = try repository.fetchVisualPreferenceState()
            let profile = VisualPreferenceProfile(
                likedCentroids: visualState?.likedCentroids ?? [],
                dislikedCentroids: visualState?.dislikedCentroids ?? []
            )
            let calibrationProgress = visualState?.calibrationProgress ?? 0
            let isTrained = visualState?.isTrained ?? false

            guard let detail = profile.matchDetail(forEmbedding: embedding) else {
                let result = StyleCheckResult(
                    verdict: .notEnoughData, detail: nil,
                    calibrationProgress: calibrationProgress, isTrained: isTrained
                )
                state = .result(result)
                logResult(result)
                return
            }

            let verdict: StyleCheckVerdict
            if detail.bonus >= Self.verdictThreshold {
                verdict = .matchesStyle
            } else if detail.bonus <= -Self.verdictThreshold {
                verdict = .notYourStyle
            } else {
                verdict = .mixedSignals
            }

            let result = StyleCheckResult(
                verdict: verdict, detail: detail,
                calibrationProgress: calibrationProgress, isTrained: isTrained
            )
            state = .result(result)
            logResult(result)
        } catch {
            state = .failed("Couldn't analyze that photo. Try a different one.")
        }
    }

    func reset() {
        state = .idle
    }

    /// Verification logging under the shared `[AI-Stylist-ML]` tag
    /// (`Domain/MLLog.swift`) — this tool exists specifically so the user can
    /// confirm the model is learning, so every manual check's raw numbers
    /// are logged alongside the swipe-deck's existing drift/rank logging.
    private func logResult(_ result: StyleCheckResult) {
        let likedSimilarity = result.detail?.likedSimilarity ?? 0
        let dislikedSimilarity = result.detail?.dislikedSimilarity ?? 0
        let bonus = result.detail?.bonus ?? 0
        MLLog.logger.notice(
            "[AI-Stylist-ML] manual style check: verdict=\(String(describing: result.verdict), privacy: .public) liked=\(likedSimilarity, format: .fixed(precision: 3), privacy: .public) disliked=\(dislikedSimilarity, format: .fixed(precision: 3), privacy: .public) bonus=\(bonus, format: .fixed(precision: 3), privacy: .public)"
        )
    }
}
