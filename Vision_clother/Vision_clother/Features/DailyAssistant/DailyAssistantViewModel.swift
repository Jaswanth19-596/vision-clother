//
//  DailyAssistantViewModel.swift
//  Vision_clother
//
//  Drives the LLM-only recommendation pipeline for Tab 1: free text →
//  StylistBrain (OpenRouter) → validator + scorer. Try-on itself runs as
//  an independent background job — see
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
    /// Hard cap on the whole weather → profile → recommendation stretch.
    /// Neither `URLSession.shared` (used by every OpenRouter service in this
    /// chain) nor any call site configures its own request timeout, so a
    /// degraded connection could otherwise leave `extractionState` stuck at
    /// `.loading` indefinitely with no error ever surfaced — this guarantees
    /// the UI always resolves.
    private static let requestTimeoutNanoseconds: UInt64 = 15_000_000_000

    /// Clarification Loop (Stylist Intelligence Engine ADR, Phase 2): the
    /// maximum number of clarifying follow-ups the recommendation call may
    /// ask before it's forced to decide (see `StylistBrain`'s FINAL TURN
    /// instruction). A turn is "honored" when the model actually asks a
    /// clarifying question — the forced-decision turn itself doesn't count
    /// against this cap, it's what the cap triggers.
    static let maxClarificationTurns = 2

    private enum RequestOutcome {
        case success([OutfitCombination])
        case clarification(followUpText: String, chips: [String])
        case failure(String)
        case timedOut
    }

    enum ExtractionState: Equatable {
        case idle
        case loading
        /// Clarification Loop (Stylist Intelligence Engine ADR, Phase 2):
        /// the recommendation call judged the occasion ambiguous (or the
        /// message off-topic) and is asking a follow-up instead of forcing
        /// outfits. `chips` are tappable quick replies; a free-text reply
        /// via the prompt field works identically (`continueConversation`).
        case awaitingClarification(followUpText: String, chips: [String])
        /// Broadened from a single `IntentExtractionError` (pre-2026-07-10)
        /// to a pre-formatted message: the primary path
        /// (`Services/OutfitRecommendationService.swift`) has its own error
        /// type, so there is no single error type left to hold here.
        case failed(String)

        static func == (lhs: ExtractionState, rhs: ExtractionState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.failed, .failed), (.awaitingClarification, .awaitingClarification):
                return true
            default:
                return false
            }
        }
    }

    /// Conversational Refinement Loop (Stylist Intelligence Engine ADR,
    /// Phase 2 addendum): one full request/response cycle in the chat
    /// timeline the UI renders — distinct from `ConversationTurn`, which is
    /// the LLM-facing replay unit. A round is either a pending clarifying
    /// question or a resolved set of outfits.
    struct ConversationRound: Identifiable {
        enum Outcome {
            case clarification(followUpText: String, chips: [String])
            case outfits([OutfitCombination])
        }

        let id = UUID()
        var userText: String
        var outcome: Outcome
    }

    var prompt: String = ""
    var extractionState: ExtractionState = .idle
    /// Full chat-timeline history for the conversation currently in
    /// progress — reset by `requestOutfitIdeas()` (a brand-new topic) and by
    /// `resetConversation()`; appended to, never reset, by
    /// `continueConversation(with:)`.
    var rounds: [ConversationRound] = []
    /// The most recently resolved outfits, or empty if the latest round is
    /// still a pending clarification (or there's no round yet). Derived
    /// rather than separately maintained so it can never drift from `rounds`.
    var candidates: [OutfitCombination] {
        guard case .outfits(let outfits) = rounds.last?.outcome else { return [] }
        return outfits
    }
    /// LLM replay transcript — reset to empty by `requestOutfitIdeas()` and
    /// by `resetConversation()`; extended, never reset, by
    /// `continueConversation(with:)`. Purely request-building state, distinct
    /// from `rounds` (the UI-facing history): a successful round's assistant
    /// turn here is a compact machine-readable summary
    /// (`assistantSummaryText(for:)`), not the prose the UI shows.
    private var conversationHistory: [ConversationTurn] = []
    private var clarificationTurnCount: Int = 0

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
        recommendationService: OutfitRecommendationService = MockOutfitRecommendationService(),
        weatherProvider: CurrentWeatherProviding = MockCurrentWeatherProvider(),
        profileDerivationService: UserProfileDerivationService = MockUserProfileDerivationService()
    ) {
        self.repository = repository
        self.jobQueueStore = jobQueueStore
        self.recommendationService = recommendationService
        self.weatherProvider = weatherProvider
        self.profileDerivationService = profileDerivationService
    }

    /// Primary path (PRD §2.1a): prompt + bounded wardrobe catalog + style
    /// profile + weather → recommendation LLM → validated outfits. If the
    /// catalog is empty, the LLM call fails, or validation yields nothing
    /// usable, returns `.failure` with a descriptive error message. Safe to
    /// call again while `.failed` — that's exactly the manual-retry path the
    /// UI's Retry button uses. Starts a brand-new conversation — resets any
    /// in-progress clarification loop, so this always reads as a fresh topic
    /// rather than a continuation of whatever the user was previously asked.
    func requestOutfitIdeas() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cleared here, not by the caller before this runs — `prompt` is
        // read above synchronously, before any suspension point, so this
        // can't race a fresh keystroke; clearing it from the View instead
        // (before this `async` call even starts) would empty `prompt` out
        // from under this same guard on the next call.
        prompt = ""
        conversationHistory = []
        clarificationTurnCount = 0
        rounds = []
        await sendTurn(userText: trimmed)
    }

    /// Continues the SAME conversation — called identically by a chip tap
    /// (the chip's own label as `text`), a free-text reply to a pending
    /// clarification, and a post-result refinement ("no bag or graphic
    /// shirt today, give me something else"). The only requirement is that
    /// a conversation is already in progress; unlike a clarification reply,
    /// a refinement turn is uncapped and never touches
    /// `clarificationTurnCount` (see `sendTurn`/`resolveOutfits`). Never
    /// resets `conversationHistory` or `rounds`.
    func continueConversation(with text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !conversationHistory.isEmpty, extractionState != .loading else { return }
        prompt = ""
        await sendTurn(userText: trimmed)
    }

    /// Re-sends the turn that just failed, instead of `requestOutfitIdeas()`
    /// wiping the whole conversation — safe now that a failure can happen
    /// several refinement rounds into a conversation, not only on turn 1.
    /// `sendTurn` already appended the failed attempt's user turn to
    /// `conversationHistory` before the network/decoding error surfaced, so
    /// it's popped here before re-sending to avoid a duplicate.
    func retryLastTurn() async {
        guard case .failed = extractionState else { return }
        guard let lastUserText = conversationHistory.last(where: { $0.role == .user })?.text else {
            await requestOutfitIdeas()
            return
        }
        if conversationHistory.last?.role == .user {
            conversationHistory.removeLast()
        }
        await sendTurn(userText: lastUserText)
    }

    /// Abandons the current conversation entirely so the next
    /// `requestOutfitIdeas()` starts a genuinely fresh topic. Wired to the
    /// "New" toolbar action.
    func resetConversation() {
        conversationHistory = []
        clarificationTurnCount = 0
        extractionState = .idle
        rounds = []
    }

    private func sendTurn(userText: String) async {
        conversationHistory.append(ConversationTurn(role: .user, text: userText))

        extractionState = .loading

        let requestID = UUID()
        currentRequestID = requestID
        let isFinalTurn = clarificationTurnCount >= Self.maxClarificationTurns
        let historySnapshot = conversationHistory

        // Races the whole resolution flow against a hard deadline instead of
        // trusting each network call's own timeout — cancelling `workTask`
        // on timeout cooperatively aborts any in-flight URLSession request
        // too, rather than leaving it running in the background.
        let workTask = Task {
            await PerfLog.time("resolveOutfits.total") {
                await self.resolveOutfits(conversationHistory: historySnapshot, isFinalTurn: isFinalTurn)
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.requestTimeoutNanoseconds)
            workTask.cancel()
        }

        let outcome = await workTask.value
        timeoutTask.cancel()

        // A newer call to requestOutfitIdeas()/replyToClarification() (or
        // the retry button) already superseded this one — don't clobber its
        // state with our late result.
        guard currentRequestID == requestID else { return }

        switch outcome {
        case .success(let resolved):
            rounds.append(ConversationRound(userText: userText, outcome: .outfits(resolved)))
            conversationHistory.append(ConversationTurn(role: .assistant, text: Self.assistantSummaryText(for: resolved)))
            extractionState = .idle
        case .clarification(let followUpText, let chips):
            rounds.append(ConversationRound(userText: userText, outcome: .clarification(followUpText: followUpText, chips: chips)))
            conversationHistory.append(ConversationTurn(role: .assistant, text: followUpText))
            clarificationTurnCount += 1
            extractionState = .awaitingClarification(followUpText: followUpText, chips: chips)
        case .failure(let message):
            extractionState = .failed(message)
        case .timedOut:
            extractionState = .failed("This is taking too long. Check your connection and try again.")
        }
    }

    /// Compact, one-line-per-outfit record of what was just recommended,
    /// appended to `conversationHistory` (not `rounds`) as the assistant's
    /// turn on a successful round. Keeps proper user/assistant alternation
    /// in the replayed transcript and lets the model resolve a later
    /// refinement turn — whether a generic exclusion ("no bag, no graphic
    /// tops") or a reference back to a specific pick ("swap the shoes on
    /// the first one") — against what it actually gave last time.
    private static func assistantSummaryText(for outfits: [OutfitCombination]) -> String {
        outfits.enumerated().map { index, outfit in
            let slots = Slot.allCases.compactMap { slot -> String? in
                guard let item = outfit.itemsBySlot[slot] else { return nil }
                return "\(slot.rawValue): \(item.displayLabel)"
            }
            return "Outfit \(index + 1) — \(slots.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    private func resolveOutfits(conversationHistory: [ConversationTurn], isFinalTurn: Bool) async -> RequestOutcome {
        let weather = await PerfLog.time("weather") { await weatherProvider.currentWeather() }

        do {
            let inventory = try repository.fetchInventory()
            let history = try await repository.fetchFeedbackHistory()
            let profile = await PerfLog.time("profile") { await resolvedUserProfile() }

            let (catalog, index) = await PerfLog.time("catalogBuild") { WardrobeCatalogBuilder.build(from: inventory, history: history) }
            guard !catalog.isEmpty else {
                return .failure("Your wardrobe appears to be empty. Add some items and try again.")
            }

            let response = try await PerfLog.time("recommendation.call") {
                try await recommendationService.recommendOutfits(
                    conversationHistory: conversationHistory, isFinalTurn: isFinalTurn,
                    catalog: catalog, profile: profile, weather: weather, history: history
                )
            }
            // Clarification Loop (Stylist Intelligence Engine ADR,
            // Phase 2): the model asked a follow-up instead of
            // deciding. Only honored while `!isFinalTurn` — a
            // model that disobeys the FINAL TURN instruction and
            // still reports `intentClear == false` on the forced
            // turn falls through to validation below exactly like
            // any other empty result, rather than looping into a
            // 4th clarification round.
            if !response.intentClear && !isFinalTurn {
                return .clarification(
                    followUpText: response.followUpText ?? "Could you tell me more about the occasion?",
                    chips: response.suggestedChips
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
            guard !validated.isEmpty else {
                return .failure("Couldn’t find outfits matching your request. Try rephrasing or adding more items to your wardrobe.")
            }
            return .success(validated)
        } catch is CancellationError {
            return .timedOut
        } catch {
            // URLSession surfaces cooperative cancellation (from the timeout
            // deadline above) as `URLError.cancelled`, not `CancellationError`.
            if (error as? URLError)?.code == .cancelled {
                return .timedOut
            }
            Self.logger.debug("Outfit recommendation failed: \(String(describing: error))")
            return .failure(error.localizedDescription)
        }
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
