//
//  DailyAssistantViewModel.swift
//  Vision_clother
//
//  Drives PRD.md §2.1's full pipeline for Tab 1: free text -> intent
//  extraction (OpenRouter) -> local retrieval + scoring
//  (OutfitRecommendationEngine) -> optional try-on render. Try-on itself now
//  runs as an independent background job — see
//  `Features/JobQueue/JobQueueStore.swift` — so multiple renders can be in
//  flight at once without this view model owning a single cancel-and-replace
//  `Task`.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class DailyAssistantViewModel {
    private static let logger = Logger(subsystem: "com.visionclother", category: "DailyAssistant")
    /// Hard cap on the whole weather -> profile -> recommendation ->
    /// deterministic-fallback stretch. Neither `URLSession.shared` (used by
    /// every OpenRouter service in this chain) nor any call site configures
    /// its own request timeout, so a degraded connection could otherwise
    /// leave `extractionState` stuck at `.loading` indefinitely with no
    /// error ever surfaced — this guarantees the UI always resolves.
    private static let requestTimeoutNanoseconds: UInt64 = 15_000_000_000

    private enum RequestOutcome {
        case success([OutfitCombination])
        case failure(String)
        case timedOut
    }

    enum ExtractionState: Equatable {
        case idle
        case loading
        /// Broadened from a single `IntentExtractionError` (pre-2026-07-10)
        /// to a pre-formatted message: the primary path
        /// (`Services/OutfitRecommendationService.swift`) and the fallback
        /// path (`Services/OpenRouterIntentExtractionService.swift`) each
        /// have their own error types, and the fallback itself only
        /// surfaces once *both* paths have failed — so there's no single
        /// error type left to hold here.
        case failed(String)

        static func == (lhs: ExtractionState, rhs: ExtractionState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.failed, .failed):
                return true
            default:
                return false
            }
        }
    }

    var prompt: String = ""
    var extractionState: ExtractionState = .idle
    var candidates: [OutfitCombination] = []

    private let intentService: IntentExtractionService
    private let repository: WardrobeRepository
    private let jobQueueStore: JobQueueStore
    /// Primary recommendation path (PRD §2.1a, the 2026-07-10
    /// LLM-as-Recommender reversal — docs/decisions/resolved-v1.md).
    private let recommendationService: OutfitRecommendationService
    private let weatherProvider: CurrentWeatherProviding
    /// Backs the lazy profile backfill in `requestOutfitIdeas()` — derives
    /// once from an existing portrait if `fetchUserProfile()` is still nil,
    /// mirroring the eager derivation `ManualPairingViewModel.savePortrait`
    /// already does on a fresh portrait save.
    private let profileDerivationService: UserProfileDerivationService
    /// Guards against a stale request's result overwriting a newer one when
    /// two `requestOutfitIdeas()` calls overlap (e.g. a race between the
    /// prompt field's Return-key submit and the button) and against a
    /// timed-out request's late result landing after `.failed` was already
    /// shown.
    private var currentRequestID: UUID?

    init(
        repository: WardrobeRepository,
        jobQueueStore: JobQueueStore,
        intentService: IntentExtractionService = MockIntentExtractionService(),
        recommendationService: OutfitRecommendationService = MockOutfitRecommendationService(),
        weatherProvider: CurrentWeatherProviding = MockCurrentWeatherProvider(),
        profileDerivationService: UserProfileDerivationService = MockUserProfileDerivationService()
    ) {
        self.repository = repository
        self.jobQueueStore = jobQueueStore
        self.intentService = intentService
        self.recommendationService = recommendationService
        self.weatherProvider = weatherProvider
        self.profileDerivationService = profileDerivationService
    }

    /// Primary path (PRD §2.1a): prompt + bounded wardrobe catalog + style
    /// profile + weather -> recommendation LLM -> validated outfits. Falls
    /// back to the fully deterministic §2.1 pipeline (intent extraction ->
    /// `OutfitRecommendationEngine`) when AI recommendations are disabled
    /// (`RecommendationSettings.useAIRecommendations`), the recommendation
    /// call fails, or validation yields nothing usable — so the app always
    /// produces an outfit when the inventory can support one. Safe to call
    /// again while `.failed` — that's exactly the manual-retry path the
    /// UI's Retry button uses.
    func requestOutfitIdeas() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        extractionState = .loading
        candidates = []

        let requestID = UUID()
        currentRequestID = requestID

        // Races the whole resolution flow against a hard deadline instead of
        // trusting each network call's own timeout — cancelling `workTask`
        // on timeout cooperatively aborts any in-flight URLSession request
        // too, rather than leaving it running in the background.
        let workTask = Task {
            await PerfLog.time("resolveOutfits.total") { await self.resolveOutfits(trimmed: trimmed) }
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.requestTimeoutNanoseconds)
            workTask.cancel()
        }

        let outcome = await workTask.value
        timeoutTask.cancel()

        // A newer call to requestOutfitIdeas() (or the retry button) already
        // superseded this one — don't clobber its state with our late result.
        guard currentRequestID == requestID else { return }

        switch outcome {
        case .success(let resolved):
            candidates = resolved
            extractionState = .idle
        case .failure(let message):
            extractionState = .failed(message)
        case .timedOut:
            extractionState = .failed("This is taking too long. Check your connection and try again.")
        }
    }

    private func resolveOutfits(trimmed: String) async -> RequestOutcome {
        let weather = await PerfLog.time("weather") { await weatherProvider.currentWeather() }

        do {
            let inventory = try repository.fetchInventory()
            let history = try repository.fetchFeedbackHistory()
            let profile = await PerfLog.time("profile") { await resolvedUserProfile() }

            if RecommendationSettings.useAIRecommendations {
                let (catalog, index) = await PerfLog.time("catalogBuild") { WardrobeCatalogBuilder.build(from: inventory) }
                if !catalog.isEmpty {
                    do {
                        let response = try await PerfLog.time("recommendation.call") {
                            try await recommendationService.recommendOutfits(
                                prompt: trimmed, catalog: catalog, profile: profile, weather: weather, history: history
                            )
                        }
                        let validated = await PerfLog.time("validation") {
                            OutfitRecommendationValidator.validate(
                                response,
                                index: index,
                                // Self-reported by the same call, not a second
                                // intent-extraction round-trip (Stylist Intelligence
                                // Engine ADR) — closes the gap where Tier 1 dress-code
                                // alignment was previously unenforced on the LLM path.
                                constraints: response.resolvedConstraints,
                                profile: profile,
                                weather: weather,
                                history: history
                            )
                        }
                        if !validated.isEmpty {
                            let topped = await PerfLog.time("topUp") {
                                await topUpIfNeeded(
                                    validated: validated,
                                    prompt: trimmed,
                                    inventory: inventory,
                                    resolvedConstraints: response.resolvedConstraints,
                                    profile: profile,
                                    weather: weather,
                                    history: history
                                )
                            }
                            return .success(topped)
                        }
                    } catch {
                        // Previously swallowed via `try?` with no logging at
                        // all — falling back to the deterministic engine is
                        // correct by design, but a silently-and-permanently
                        // failing AI path (bad API key, persistent decoding
                        // failures) was otherwise undiagnosable.
                        Self.logger.debug("AI outfit recommendation failed, falling back to deterministic engine: \(String(describing: error))")
                    }
                }
                // Falls through to the deterministic pipeline below when AI
                // recommendations are disabled, the catalog is empty, the
                // recommendation call fails, or every pick fails validation.
            }

            let constraints = try await PerfLog.time("intentExtraction.fallbackCall") {
                try await intentService.extractConstraints(prompt: trimmed, weather: weather)
            }
            let generated = await PerfLog.time("deterministicGenerate") {
                OutfitRecommendationEngine.generateCandidates(
                    inventory: inventory,
                    constraints: constraints,
                    profile: profile,
                    weather: weather,
                    history: history
                )
            }
            return .success(generated)
        } catch is CancellationError {
            return .timedOut
        } catch let error as IntentExtractionError {
            return .failure(error.errorDescription ?? "Couldn't understand that.")
        } catch {
            // URLSession surfaces cooperative cancellation (from the timeout
            // deadline above) as `URLError.cancelled`, not `CancellationError`.
            if (error as? URLError)?.code == .cancelled {
                return .timedOut
            }
            return .failure(error.localizedDescription)
        }
    }

    /// Guarantees the user sees at least `minimumCount` outfits when the LLM
    /// path under-returns (schema/prompt only hint at 3-5 — the validator can
    /// still drop picks below that after the fact). Tops up with the
    /// deterministic engine, excluding any item set already present in
    /// `validated`, and re-sorts the merged list by score. Never discards a
    /// validated (rationale-bearing) outfit to make room.
    private func topUpIfNeeded(
        validated: [OutfitCombination],
        prompt: String,
        inventory: [WardrobeItem],
        resolvedConstraints: StyleConstraints?,
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async -> [OutfitCombination] {
        let minimumCount = 3
        let shortfall = minimumCount - validated.count
        guard shortfall > 0 else { return validated }

        let constraints: StyleConstraints
        if let resolvedConstraints {
            constraints = resolvedConstraints
        } else if let extracted = try? await PerfLog.time("intentExtraction.topUpCall", {
            try await intentService.extractConstraints(prompt: prompt, weather: weather)
        }) {
            constraints = extracted
        } else {
            return validated
        }

        let usedItemSets = Set(validated.map { Set($0.items.map(\.id)) })
        let deterministic = OutfitRecommendationEngine.generateCandidates(
            inventory: inventory,
            constraints: constraints,
            profile: profile,
            weather: weather,
            history: history,
            limit: shortfall + 5
        )
        let additions = deterministic
            .filter { !usedItemSets.contains(Set($0.items.map(\.id))) }
            .prefix(shortfall)

        return (validated + additions).sorted { $0.score > $1.score }
    }

    /// Reads the persisted style profile, lazily deriving it once from an
    /// existing portrait if none is saved yet (PRD §3.8). Best-effort: a
    /// derivation failure just means this and future calls proceed with
    /// `nil` until the user saves a fresh portrait (which derives eagerly,
    /// see `ManualPairingViewModel.savePortrait`).
    private func resolvedUserProfile() async -> UserStyleProfile? {
        if let existing = try? repository.fetchUserProfile() {
            return existing
        }
        guard let portraitData = UserPortraitStorage.load() else { return nil }
        do {
            let wire = try await PerfLog.time("profile.derivationNetworkCall") {
                try await profileDerivationService.deriveProfile(portraitData: portraitData)
            }
            try? repository.saveUserProfile(wire)
            return try? repository.fetchUserProfile()
        } catch {
            Self.logger.debug("User style profile derivation failed, continuing without a profile: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Try-on

    /// Hands off to the background job queue — see `JobQueueStore.swift`.
    /// Independent per call: starting a second try-on never cancels a first
    /// one in flight.
    func startTryOn(baseImageData: Data, outfit: OutfitCombination) {
        jobQueueStore.enqueueTryOn(baseImageData: baseImageData, outfit: outfit)
    }
}
