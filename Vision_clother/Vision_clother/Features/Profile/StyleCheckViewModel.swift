//
//  StyleCheckViewModel.swift
//  Vision_clother
//
//  Swipe-to-Learn taste, verification tool: lets the user hand the app one
//  arbitrary clothing photo (not a swipe-deck card, not added to the closet)
//  and see whether it matches what their swipes + ratings have taught the
//  *attribute* preference model (`Domain/AttributePreferenceProfile.swift`) —
//  the same space that actually drives recommendations, so this now reflects
//  what the app will really do, not an opaque pixel-embedding side-channel.
//  The photo is tagged by the vision LLM's scene extraction (`extractSceneMetadata`,
//  robust to a raw un-isolated upload) — the primary detected garment is
//  scored, and everything is discarded — nothing is persisted.
//

import Foundation
import Observation
import os

/// One check's outcome. `.notEnoughData` is distinct from a neutral/mixed
/// score — it fires when the attribute profile has learned nothing yet (no
/// swipes or ratings), where a "mixed signals" verdict would be misleading.
enum StyleCheckVerdict: Equatable {
    case matchesStyle
    case notYourStyle
    case mixedSignals
    case notEnoughData
}

struct StyleCheckResult: Equatable {
    let verdict: StyleCheckVerdict
    /// `nil` only for `.notEnoughData`, where there's nothing to score against.
    let detail: AttributeMatchDetail?
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
    /// rather than noise — a fifth of `AttributePreferenceProfile.maxBonusMagnitude`
    /// (0.3), matching the prior visual verifier's threshold so the verdict
    /// wording stays calibrated the same way.
    private static let verdictThreshold = 0.06

    /// Downscale before the vision call — attribute extraction is coarse, so a
    /// smaller image keeps the (single, deliberate) tagging call cheap.
    private static let taggingMaxDimension: CGFloat = 768

    private let repository: WardrobeRepository
    private let visionService: VisionMetadataExtractionService

    init(repository: WardrobeRepository, visionService: VisionMetadataExtractionService) {
        self.repository = repository
        self.visionService = visionService
    }

    func checkPhoto(_ imageData: Data) async {
        state = .analyzing
        do {
            let downscaled = ImageStorage.downscaledPNGForUpload(imageData, maxDimension: Self.taggingMaxDimension)
            let sceneMetadata = try await visionService.extractSceneMetadata(imageData: downscaled)
            guard let metadata = sceneMetadata.garments.first else {
                state = .failed("Couldn't identify a garment in that photo. Try a different one.")
                return
            }
            let history = try await repository.fetchFeedbackHistory()
            let profile = history.attributeProfile

            guard profile.hasSignal else {
                let result = StyleCheckResult(verdict: .notEnoughData, detail: nil)
                state = .result(result)
                logResult(result)
                return
            }

            // Transient (never inserted) item — `matchDetail` only reads its
            // attribute fields.
            let item = WardrobeItem.make(from: metadata, imageAssetName: nil)
            let detail = profile.matchDetail(for: item)

            let verdict: StyleCheckVerdict
            if detail.bonus >= Self.verdictThreshold {
                verdict = .matchesStyle
            } else if detail.bonus <= -Self.verdictThreshold {
                verdict = .notYourStyle
            } else {
                verdict = .mixedSignals
            }

            let result = StyleCheckResult(verdict: verdict, detail: detail)
            state = .result(result)
            logResult(result)
        } catch {
            MLLog.logger.error("manual style check: failed — \(String(describing: error), privacy: .public)")
            let message = (error as? VisionMetadataExtractionError)?.errorDescription
                ?? "Couldn't analyze that photo. Try a different one."
            state = .failed(message)
        }
    }

    func reset() {
        state = .idle
    }

    /// Verification logging under the shared `[AI-Stylist-ML]` tag
    /// (`Domain/MLLog.swift`) — this tool exists specifically so the user can
    /// confirm the model is learning, so every manual check's numbers are
    /// logged alongside the swipe-deck's existing signal logging.
    private func logResult(_ result: StyleCheckResult) {
        let bonus = result.detail?.bonus ?? 0
        let componentCount = result.detail?.components.count ?? 0
        MLLog.logger.notice(
            "[AI-Stylist-ML] manual style check: verdict=\(String(describing: result.verdict), privacy: .public) bonus=\(bonus, format: .fixed(precision: 3), privacy: .public) components=\(componentCount, privacy: .public)"
        )
    }
}
