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

import Combine
import Foundation
import Observation
import os

@Observable
@MainActor
final class DailyAssistantViewModel {
    private static let logger = Logger(subsystem: "com.visionclother", category: "DailyAssistant")

    /// Answers "why did the LLM path yield fewer/zero outfits" from a log
    /// line alone — `Domain/OutfitRecommendationValidator.swift`'s
    /// `validateVerbose` already computes the per-outfit rejection reason,
    /// it just had no caller until now. Logged through `MLLog` (not
    /// `AppLog`) since this is exactly the AI-Stylist-ML diagnostic surface
    /// that logger was already built for.
    private static func logValidationOutcome(offered: Int, kept: Int, rejections: [OutfitRecommendationValidator.RejectionReason]) {
        guard kept < offered || !rejections.isEmpty else {
            MLLog.logger.notice("validation: offered=\(offered) kept=\(kept) — all outfits survived")
            return
        }
        let histogram = Dictionary(grouping: rejections, by: { String(describing: $0) }).mapValues(\.count)
        MLLog.logger.notice("validation: offered=\(offered) kept=\(kept) rejections=\(histogram)")
    }
    /// Hard cap on the whole weather → profile → recommendation stretch.
    /// Neither `URLSession.shared` (used by every OpenRouter service in this
    /// chain) nor any call site configures its own request timeout, so a
    /// degraded connection could otherwise leave `extractionState` stuck at
    /// `.loading` indefinitely with no error ever surfaced — this guarantees
    /// the UI always resolves.
    private static let requestTimeoutNanoseconds: UInt64 = 15_000_000_000

    /// Prospective Purchase Evaluation (2026-07-15): a longer budget than
    /// `requestTimeoutNanoseconds` since this path chains isolate + vision
    /// tagging (two extra network-ish legs) in front of the same
    /// weather/profile/recommendation stretch — matches
    /// `OpenRouterTryOnRenderService`'s precedent of a wider timeout (120s
    /// request timeout) for a multi-step, multi-image pipeline.
    private static let prospectivePurchaseTimeoutNanoseconds: UInt64 = 45_000_000_000

    private static let prospectivePurchaseScenarioText = "The user is deciding whether to buy the item flagged as their prospective purchase in the wardrobe catalog. Build the best, most versatile, everyday-appropriate outfits using their real wardrobe, built around that item."

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
            /// Prospective Purchase Evaluation (2026-07-15): the result of
            /// `checkProspectiveItem()`, distinct from an ordinary `.outfits`
            /// round because it always carries the specific item being
            /// evaluated — needed both to render its thumbnail in the
            /// "doesn't pair well" case (`outfits.isEmpty`) and to back the
            /// Add to Closet / Not Buying This actions regardless of match
            /// outcome. `note` is the model's own `follow_up_text` when it
            /// chose to explain a no-match verdict, `nil` otherwise.
            case purchaseCheck(item: WardrobeItem, outfits: [OutfitCombination], note: String?)
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

    /// Prospective Purchase Evaluation (2026-07-15): bound to the "Buying
    /// something new?" toggle in `DailyAssistantView`. Independent of
    /// `conversationHistory`/`clarificationTurnCount` — this mode is a fixed,
    /// one-shot evaluation with no scenario text and no clarification loop,
    /// so it never touches the free-text conversational state.
    var isProspectivePurchaseMode: Bool = false
    /// The photo the user just attached, staged until `checkProspectiveItem()`
    /// consumes it. Cleared as soon as that call starts (mirrors `prompt`
    /// being cleared synchronously before `requestOutfitIdeas()`'s own
    /// `async` work begins).
    var attachedProspectiveImageData: Data?
    /// Kept only so `retryLastTurn()` can tell which flow actually produced
    /// the current `.failed` state and retry the right thing — cleared at
    /// the top of `sendTurn` so a later free-text failure can't be mistaken
    /// for a stale purchase-check retry.
    private var lastProspectiveRawImageData: Data?

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
    /// Quota visibility feature: optimistic recommendation-usage bump on a
    /// successful `recommendationService.recommendOutfits` call — see
    /// `Data/UsageTracker.swift`.
    private let usageTracker: UsageTracker
    /// Guards against a stale request's result overwriting a newer one when
    /// two `requestOutfitIdeas()` calls overlap (e.g. a race between the
    /// prompt field's Return-key submit and the button) and against a
    /// timed-out request's late result landing after `.failed` was already
    /// shown.
    private var currentRequestID: UUID?

    /// Mirrors of `AuthService.shared`'s `@Published` auth state — added so
    /// `DailyAssistantView` (Features/CLAUDE.md: "Views never call Services
    /// directly — always go through a ViewModel") can read auth state here
    /// instead of holding its own `@ObservedObject AuthService.shared`. A
    /// plain computed property forwarding to `AuthService.shared` wouldn't
    /// be reactive — `@Observable`'s change tracking only fires on this
    /// class's own stored property writes, not on a Combine `@Published`
    /// read nested inside a computed property — so these are actively kept
    /// in sync via `bindAuthState()`'s Combine subscriptions instead.
    private(set) var isAnonymous = AuthService.shared.isAnonymous
    private(set) var uid: String? = AuthService.shared.uid
    private var authCancellables = Set<AnyCancellable>()

    init(
        repository: WardrobeRepository,
        jobQueueStore: JobQueueStore,
        recommendationService: OutfitRecommendationService = MockOutfitRecommendationService(),
        weatherProvider: CurrentWeatherProviding = MockCurrentWeatherProvider(),
        profileDerivationService: UserProfileDerivationService = MockUserProfileDerivationService(),
        usageTracker: UsageTracker
    ) {
        self.repository = repository
        self.jobQueueStore = jobQueueStore
        self.recommendationService = recommendationService
        self.weatherProvider = weatherProvider
        self.profileDerivationService = profileDerivationService
        self.usageTracker = usageTracker
        bindAuthState()
    }

    private func bindAuthState() {
        AuthService.shared.$isAnonymous
            .sink { [weak self] in self?.isAnonymous = $0 }
            .store(in: &authCancellables)
        AuthService.shared.$uid
            .sink { [weak self] in self?.uid = $0 }
            .store(in: &authCancellables)
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
        // Prospective Purchase Evaluation: that flow never touches
        // `conversationHistory`, so it needs its own retry branch — checked
        // first since it's the more recently-set of the two.
        if let rawImageData = lastProspectiveRawImageData {
            await performProspectivePurchaseCheck(rawImageData: rawImageData)
            return
        }
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
        isProspectivePurchaseMode = false
        attachedProspectiveImageData = nil
        lastProspectiveRawImageData = nil
    }

    private func sendTurn(userText: String) async {
        conversationHistory.append(ConversationTurn(role: .user, text: userText))
        // A normal free-text turn is starting — any earlier purchase-check
        // failure is no longer "the most recent thing that could be retried".
        lastProspectiveRawImageData = nil

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
            let round = ConversationRound(userText: userText, outcome: .outfits(resolved))
            rounds.append(round)
            conversationHistory.append(ConversationTurn(role: .assistant, text: Self.assistantSummaryText(for: resolved)))
            extractionState = .idle
            // Impression/Selection Event Capture (Stylist Intelligence Engine
            // ADR): best-effort — a logging/audit trail, never a gate on the
            // conversation flow.
            try? repository.recordImpressions(roundID: round.id, outfits: resolved)
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
            var slots = Slot.allCases.compactMap { slot -> String? in
                guard let item = outfit.itemsBySlot[slot] else { return nil }
                return "\(slot.rawValue): \(item.displayLabel)"
            }
            slots += outfit.supplementaryAccessories.map { "supplementary_accessory: \($0.displayLabel)" }
            return "Outfit \(index + 1) — \(slots.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    /// HIGH-2 perf fix: the inventory/feedback-history cache that used to
    /// live here as `inventoryCache`/`feedbackHistoryCache` moved down into
    /// `SwiftDataWardrobeRepository` (`Data/WardrobeRepository.swift`) itself
    /// — this repository instance is held for this view model's whole
    /// lifetime (`DailyAssistantView`'s `.task { viewModel == nil ... }`
    /// guard constructs it once per tab), so it gets the exact same
    /// first-call-pays / every-later-call-is-cached behavior this used to
    /// implement locally, and any other long-lived repository holder gets it
    /// for free too instead of reimplementing this cache per call site.
    private func wardrobeSnapshot() async throws -> (inventory: [WardrobeItem], history: FeedbackHistory) {
        let inventory = try repository.fetchInventory()
        let history = try await repository.fetchFeedbackHistory()
        return (inventory, history)
    }

    private func resolveOutfits(conversationHistory: [ConversationTurn], isFinalTurn: Bool) async -> RequestOutcome {
        do {
            // Weather, the wardrobe snapshot, and the profile don't depend on
            // each other — only the catalog build (below) needs the
            // snapshot's inventory/history, so fan all three out instead of
            // stacking their round-trips sequentially.
            async let weatherResult = PerfLog.time("weather") { await weatherProvider.currentWeather() }
            async let snapshotResult = wardrobeSnapshot()
            async let profileResult = PerfLog.time("profile") { await resolvedUserProfile() }

            let (inventory, history) = try await snapshotResult
            let weather = await weatherResult
            let profile = await profileResult

            let (catalog, _) = await PerfLog.time("catalogBuild") { WardrobeCatalogBuilder.build(from: inventory, history: history) }
            guard !catalog.isEmpty else {
                return .failure("Your wardrobe appears to be empty. Add some items and try again.")
            }

            let response = try await PerfLog.time("recommendation.call") {
                try await recommendationService.recommendOutfits(
                    conversationHistory: conversationHistory, isFinalTurn: isFinalTurn,
                    catalog: catalog, profile: profile, weather: weather, history: history
                )
            }
            // A call that reaches this point already cleared the server's
            // quotaGate("recommendation") — see backend/functions/src/
            // middleware/quota.ts — so the monthly counter has already been
            // incremented server-side regardless of what this response
            // resolves to (clarification vs. outfits). Bump the local
            // optimistic mirror here so the UI reflects it instantly.
            usageTracker.recordRecommendationUsed()
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
            // Re-fetch rather than reuse `index`: `recommendationService
            // .recommendOutfits` above is a multi-second network `await`, a
            // suspension point during which this MainActor is reentrant —
            // `WardrobeSyncCoordinator.reconcileIfSignedIn()` (fired on every
            // `scenePhase -> .active`, e.g. a photo picker dismissing while
            // adding an item) can run `applyWardrobeItemChange` in that
            // window, which does `modelContext.delete` + re-`insert` on any
            // wardrobe item a pull touches — including a self-echo of an
            // item this device just pushed. That invalidates the exact
            // `WardrobeItem` objects `index` was holding, and reading a
            // property (e.g. `.slot`) on an invalidated SwiftData object
            // traps. `fetchInventory()` is version-cached (`Data/WardrobeRepository.swift`),
            // so this is cheap when no such reconcile happened and only does
            // real work when one did — the ids the LLM returned still
            // resolve identically, just to live objects.
            let freshIndex: [String: WardrobeItem] = Dictionary(
                uniqueKeysWithValues: (try repository.fetchInventory())
                    .filter { !$0.isGhostElement }
                    .map { ($0.id.uuidString, $0) }
            )
            let (validated, rejections) = await PerfLog.time("validation") {
                OutfitRecommendationValidator.validateVerbose(
                    response,
                    index: freshIndex,
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
            Self.logValidationOutcome(offered: response.outfits.count, kept: validated.count, rejections: rejections)
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

    // MARK: - Prospective Purchase Evaluation

    private enum ProspectivePurchaseOutcome {
        case resolved(item: WardrobeItem, outfits: [OutfitCombination], note: String?)
        case failure(String)
        case timedOut
    }

    /// Entry point for the "Buying something new?" toggle — tags the
    /// attached photo and asks the recommendation LLM to build the best
    /// outfits around it, using the user's real wardrobe. Deliberately
    /// independent of the free-text conversational flow: no scenario text,
    /// no clarification loop, and it never touches `conversationHistory`.
    func checkProspectiveItem() async {
        guard let rawImageData = attachedProspectiveImageData else { return }
        attachedProspectiveImageData = nil
        isProspectivePurchaseMode = false
        await performProspectivePurchaseCheck(rawImageData: rawImageData)
    }

    /// Shared by `checkProspectiveItem()` and `retryLastTurn()`'s
    /// purchase-check branch — kept separate from `checkProspectiveItem()`
    /// itself since a retry must not re-read/clear `attachedProspectiveImageData`
    /// (the user may have already started attaching a different photo).
    private func performProspectivePurchaseCheck(rawImageData: Data) async {
        lastProspectiveRawImageData = rawImageData
        extractionState = .loading

        let requestID = UUID()
        currentRequestID = requestID

        let workTask = Task {
            await PerfLog.time("resolveProspectivePurchase.total") {
                await self.resolveProspectivePurchase(rawImageData: rawImageData)
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.prospectivePurchaseTimeoutNanoseconds)
            workTask.cancel()
        }

        let outcome = await workTask.value
        timeoutTask.cancel()

        guard currentRequestID == requestID else { return }

        switch outcome {
        case .resolved(let item, let outfits, let note):
            let round = ConversationRound(userText: "Is this a good buy?", outcome: .purchaseCheck(item: item, outfits: outfits, note: note))
            rounds.append(round)
            extractionState = .idle
            if !outfits.isEmpty {
                // Impression/Selection Event Capture: same best-effort
                // logging every ordinary recommendation round gets.
                try? repository.recordImpressions(roundID: round.id, outfits: outfits)
            }
        case .failure(let message):
            extractionState = .failed(message)
        case .timedOut:
            extractionState = .failed("This is taking too long. Check your connection and try again.")
        }
    }

    /// Isolates + tags the photo (reusing `JobQueueStore`'s existing
    /// services, not enqueued as a tracked `Job`), builds a transient
    /// `WardrobeItem` that is never saved unless the user later taps Add to
    /// Closet, and asks the recommendation LLM to build outfits forced
    /// around it (`mustIncludeItemID`). An empty `outfits` result is a
    /// legitimate answer — "this doesn't pair with anything you own" — not
    /// an error, so it's returned as `.resolved` with an empty array rather
    /// than `.failure`.
    private func resolveProspectivePurchase(rawImageData: Data) async -> ProspectivePurchaseOutcome {
        do {
            // Weather, the photo isolate+tag call, and the wardrobe snapshot
            // + profile are all independent of each other — only the catalog
            // build (below) needs both the tagged prospective item and the
            // snapshot's inventory/history, so fan all four out instead of
            // stacking their round-trips sequentially.
            async let weatherResult = PerfLog.time("weather") { await weatherProvider.currentWeather() }
            async let taggedResult = PerfLog.time("prospectivePurchase.isolateAndTag") {
                try await jobQueueStore.isolateAndTag(rawImageData: rawImageData)
            }
            async let snapshotResult = wardrobeSnapshot()
            async let profileResult = PerfLog.time("profile") { await resolvedUserProfile() }

            let (imageData, metadata) = try await taggedResult
            guard !Task.isCancelled else { return .timedOut }

            let filename = try ImageStorage.save(imageData)
            let prospectiveItem = WardrobeItem.make(from: metadata, imageAssetName: filename)
            // Same bytes just written to `filename` — captured now so that
            // if the user later adds this item to their closet
            // (`addProspectiveItemToCloset`), the next `fetchFeedbackHistory()`
            // resolves its embedding cache without a re-read/re-hash.
            prospectiveItem.imageFingerprint = ImageStorage.fingerprint(imageData)

            let (inventory, history) = try await snapshotResult
            let weather = await weatherResult
            let profile = await profileResult

            let (catalog, _) = await PerfLog.time("catalogBuild") {
                WardrobeCatalogBuilder.build(
                    from: inventory + [prospectiveItem], history: history, prospectiveItemID: prospectiveItem.id
                )
            }

            let response = try await PerfLog.time("recommendation.call") {
                try await recommendationService.recommendOutfits(
                    conversationHistory: [ConversationTurn(role: .user, text: Self.prospectivePurchaseScenarioText)],
                    isFinalTurn: true,
                    catalog: catalog, profile: profile, weather: weather, history: history
                )
            }
            usageTracker.recordRecommendationUsed()

            // Same re-fetch-don't-reuse fix as `resolveOutfits` (see its
            // comment) — the LLM call above is a long `await` that a
            // concurrent `reconcileIfSignedIn()` can land inside, invalidating
            // `index`'s real-wardrobe `WardrobeItem` objects. `prospectiveItem`
            // itself is never persisted to `ModelContext` (only saved if the
            // user later taps "Add to Closet"), so it can't have been
            // invalidated by sync — carry the same in-memory instance forward.
            let freshIndex: [String: WardrobeItem] = Dictionary(
                uniqueKeysWithValues: ((try repository.fetchInventory()).filter { !$0.isGhostElement } + [prospectiveItem])
                    .map { ($0.id.uuidString, $0) }
            )
            let (validated, rejections) = await PerfLog.time("validation") {
                OutfitRecommendationValidator.validateVerbose(
                    response, index: freshIndex,
                    constraints: response.resolvedConstraints,
                    profile: profile, weather: weather, history: history,
                    mustIncludeItemID: prospectiveItem.id
                )
            }
            Self.logValidationOutcome(offered: response.outfits.count, kept: validated.count, rejections: rejections)

            return .resolved(item: prospectiveItem, outfits: validated, note: validated.isEmpty ? response.followUpText : nil)
        } catch is CancellationError {
            return .timedOut
        } catch {
            if (error as? URLError)?.code == .cancelled {
                return .timedOut
            }
            Self.logger.debug("Prospective purchase evaluation failed: \(String(describing: error))")
            return .failure(error.localizedDescription)
        }
    }

    /// Persists the exact item that was already tagged and rendered in the
    /// round — no re-upload, same photo/metadata. Returns whether the save
    /// succeeded so the caller (a per-round `@State` in the View) can lock
    /// its button without this view model needing to track "which rounds
    /// have been saved" itself.
    @discardableResult
    func addProspectiveItemToCloset(_ item: WardrobeItem) -> Bool {
        do {
            try repository.save(item)
            return true
        } catch {
            return false
        }
    }

    /// "Not buying this" — best-effort cleanup of the temporary isolated
    /// photo written by `resolveProspectivePurchase` for an item the user
    /// decided against saving. Never fails loudly: a missing file is not
    /// worth surfacing (`ImageStorage.delete` is itself best-effort).
    func discardProspectiveItem(_ item: WardrobeItem) {
        guard let filename = item.imageAssetName else { return }
        ImageStorage.delete(filename)
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
        // Impression/Selection Event Capture: this is the concrete "pick"
        // gesture among the shown candidates — best-effort, never a gate.
        try? repository.recordSelection(outfitID: outfit.id)
        jobQueueStore.enqueueTryOn(baseImageData: baseImageData, outfit: outfit)
    }
}
