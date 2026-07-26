//
//  UsageTracker.swift
//  Vision_clother
//
//  Quota visibility feature (2026-07-17; migrated to the credit model
//  2026-07-25): the single live source of quota state consumed by every
//  point-of-use quota display/proactive-disable (Add Item, Daily Assistant,
//  Manual Pairing) and the Profile usage summary
//  (`Features/Profile/AccountSectionView.swift`). Enforcement itself is
//  unchanged and stays server-side
//  (`backend/functions/src/middleware/creditGate.ts` for recommendations/
//  try-ons, `backend/firestore.rules` for item counts) — this is purely a
//  client-side read model plus an optimistic local nudge so the UI can
//  decrement instantly on a successful call instead of waiting on a
//  Firestore round-trip.
//
//  Credit model: recommendations and try-ons both spend from one shared
//  credit wallet (`UsageDTO`: `subscription_credits_remaining` +
//  `purchased_credits_remaining`) at per-operation costs the server reports
//  via `/entitlement/limits`. "Recommendations/combinations remaining" are
//  therefore derived (credits ÷ cost), not independent counters.
//  "Combinations" is the user-facing term for a generated/rendered outfit
//  try-on (the `IMAGE_GEN` operation).
//
//  Item counts are local-only (no server fetch needed, and no optimistic-
//  vs-reconciled split the way recommendation/try-on counts need) —
//  recomputed synchronously from the repository's live inventory, split by
//  `Slot.isRequired` (core) vs. not (accessory), matching exactly how
//  `limits.itemCap` and the existing pre-save guards in
//  `AddItemViewModel`/`JobQueueStore` already group slots.
//
//  The actual cap/limit *numbers* (`limits` below) are fetched from
//  `Services/EntitlementLimitsService.swift` — `backend/functions/src/routes/entitlementLimits.ts`
//  resolves the caller's tier server-side and returns concrete numbers, so
//  this file never hardcodes a tier→number table of its own (that used to
//  live in the now-deleted `Domain/EntitlementLimits.swift`; see
//  docs/timeline.md for why it moved server-side — not a security fix, the
//  proxy/rules were always the sole enforcer either way, but it removes a
//  hand-maintained duplicate that could silently drift from the real
//  numbers).
//
//  Retained for the app's lifetime (constructed once in
//  `Vision_clotherApp.swift`, alongside `WardrobeSyncCoordinator`) so its
//  `AuthService.shared.$uid` subscription stays alive across account
//  switches.
//

import Combine
import Foundation
import Observation

@MainActor
@Observable
final class UsageTracker {
    private(set) var usage: UsageDTO?
    private(set) var coreItemCount = 0
    private(set) var accessoryItemCount = 0
    /// Server-resolved tier limits, refreshed alongside `usage` in
    /// `refreshUsage()`. Starts at `.conservativeDefault` (the guest tier's
    /// numbers) until the first successful fetch — same "don't assume
    /// higher than proven" posture `usage` itself already had.
    private(set) var limits = EntitlementLimitsResponse.conservativeDefault

    private let repository: WardrobeRepository
    private let syncService: WardrobeSyncService
    private let entitlementLimitsService: EntitlementLimitsService
    private var uidCancellable: AnyCancellable?

    /// Guards against an older, slower `refreshUsage()` call resolving after
    /// a newer one (or after an optimistic `record*Used()` bump) and
    /// clobbering good state — only the most-recently-*started* fetch's
    /// result is ever committed.
    private var refreshGeneration = 0

    init(repository: WardrobeRepository, syncService: WardrobeSyncService, entitlementLimitsService: EntitlementLimitsService) {
        self.repository = repository
        self.syncService = syncService
        self.entitlementLimitsService = entitlementLimitsService
        refreshItemCounts()
        if let uid = AuthService.shared.uid {
            usage = Self.loadCachedUsage(uid: uid)
        }
        uidCancellable = AuthService.shared.$uid
            .removeDuplicates()
            .sink { [weak self] uid in
                if let uid {
                    self?.usage = Self.loadCachedUsage(uid: uid)
                }
                Task { await self?.refreshUsage() }
            }
    }

    /// Exposed (not `private`) so point-of-use captions can distinguish
    /// "sign in for more" (guest) from "resets next month" (free tier
    /// already at its own cap) messaging without re-deriving auth state.
    var isAnonymousQuota: Bool { AuthService.shared.isAnonymous }
    var isPremium: Bool { limits.tier == "PRO" }

    // MARK: - Credit wallet (the single source of spendable balance)

    /// Per-operation credit cost, from the server-resolved `limits`
    /// (`operationCosts` on `/entitlement/limits`). RECOMMENDATION is
    /// intentionally allowed to be `0` — the server unmetered it (credits are
    /// now a pure try-on currency; see `backend/.../pricing.config.ts`), so
    /// callers must treat `0` as "unlimited" and guard the divides below,
    /// never floor it back to 1. IMAGE_GEN stays floored at 1 so a
    /// malformed/zero cost can never divide-by-zero the try-on count.
    private var recommendationCost: Int { max(0, limits.operationCosts?["RECOMMENDATION"] ?? 0) }
    private var combinationCost: Int { max(1, limits.operationCosts?["IMAGE_GEN"] ?? 5) }

    /// `true` when the server reports a 0 RECOMMENDATION cost — recommendations
    /// (and wardrobe/Insights Q&A, which shares the route) are free for every
    /// tier. Point-of-use captions/proactive-disable on the *recommend* action
    /// key off this to show "unlimited" instead of a credit countdown.
    var isRecommendationUnmetered: Bool { recommendationCost == 0 }

    /// Total spendable credits = subscription + purchased. Prefers the real
    /// credit doc (`tierId != nil`); falls back to the server-resolved
    /// `limits.creditsRemaining` (or the tier allocation) when no migrated
    /// doc is loaded yet — recommendations and try-ons both draw from this
    /// one pool (mirrors `backend/functions/src/middleware/creditGate.ts`).
    var creditsRemaining: Int {
        if let usage, usage.tierId != nil {
            return max(0, usage.subscriptionCreditsRemaining + usage.purchasedCreditsRemaining)
        }
        return limits.creditsRemaining ?? limits.creditAllocation ?? 0
    }

    /// Purchased (lifetime StoreKit) credits only — the never-reset half of
    /// the wallet, shown in Profile so a buyer can see paid credit survives
    /// the monthly refill. `0` until a migrated doc is loaded.
    var purchasedCreditsRemaining: Int {
        if let usage, usage.tierId != nil { return max(0, usage.purchasedCreditsRemaining) }
        return 0
    }

    var recommendationLimit: Int { limits.recommendationLimit }
    var combinationLimit: Int { limits.tryOnLimit }
    /// This cycle's consumed counts (`usage_counts` on the doc) — for the
    /// Profile "used this month" readout, not for gating.
    var recommendationsUsed: Int { usage?.usageCounts["RECOMMENDATION"] ?? 0 }
    var combinationsUsed: Int { usage?.usageCounts["IMAGE_GEN"] ?? 0 }

    /// How many more of each operation the remaining credits could buy. Both
    /// derive from the same shared wallet, so they are not independent
    /// counters. Try-ons are additionally clamped by the tier's `IMAGE_GEN`
    /// hard cap (guests: 0) — the credit-engine equivalent of the old
    /// guest-blocked-from-try-on 403.
    var recommendationsRemaining: Int {
        guard recommendationCost > 0 else { return .max } // unmetered — effectively unlimited
        return creditsRemaining / recommendationCost
    }
    var combinationsRemaining: Int {
        let affordable = creditsRemaining / combinationCost
        if let cap = limits.operationCaps?["IMAGE_GEN"] {
            return max(0, min(affordable, cap - combinationsUsed))
        }
        return affordable
    }

    /// Per-slot cap lookup — `AddItemViewModel.saveItem`/`JobQueueStore.performUpload`'s
    /// pre-save guards call this directly rather than re-deriving core vs.
    /// accessory themselves.
    func itemCap(for slot: Slot) -> Int { limits.itemCap[slot.rawValue] ?? 0 }
    var coreItemCap: Int { itemCap(for: .top) }
    var accessoryItemCap: Int { itemCap(for: .accessory) }
    var isCoreItemCapReached: Bool { coreItemCount >= coreItemCap }
    var isAccessoryItemCapReached: Bool { accessoryItemCount >= accessoryItemCap }

    /// Best-effort read-through. A genuinely missing Firestore doc (`nil`
    /// return, no throw) is adopted as real "0 used" state. A *failed* fetch
    /// (network blip, permission-denied while a fresh ID token propagates,
    /// decode error, ...) intentionally leaves `usage` untouched — collapsing
    /// errors into `nil` previously made any transient failure look like the
    /// quota had reset to maximum, which is the bug this guards against.
    /// Fetches resolved tier limits alongside `meta/usage` in the same pass
    /// — tier changes are rare enough that a dedicated refresh path isn't
    /// worth it. A failed limits fetch degrades to "keep the last-known
    /// `limits`" the same way a failed usage fetch does, independently of
    /// whether the usage half of this call succeeded.
    func refreshUsage() async {
        guard let uid = AuthService.shared.uid else { usage = nil; limits = .conservativeDefault; return }
        refreshGeneration += 1
        let generation = refreshGeneration
        async let usageFetch = syncService.fetchUsage(uid: uid)
        async let limitsFetch = entitlementLimitsService.fetchLimits()

        do {
            let fetched = try await usageFetch
            guard generation == refreshGeneration else {
                AppLog.debug(.viewModel, "UsageTracker.refreshUsage: superseded by a newer refresh, discarding")
                return
            }
            usage = fetched
            Self.cacheUsage(fetched, uid: uid)
        } catch {
            AppLog.error(.viewModel, "UsageTracker.refreshUsage: usage fetch failed, keeping last-known usage — \(error.localizedDescription)")
        }

        do {
            let fetchedLimits = try await limitsFetch
            guard generation == refreshGeneration else { return }
            limits = fetchedLimits
        } catch {
            AppLog.error(.viewModel, "UsageTracker.refreshUsage: limits fetch failed, keeping last-known limits — \(error.localizedDescription)")
        }

        AppLog.info(.viewModel, "UsageTracker.refreshUsage: credits=\(self.creditsRemaining) (purchased=\(self.purchasedCreditsRemaining)) recommendationsUsed=\(self.recommendationsUsed) combinationsUsed=\(self.combinationsUsed) tier=\(self.limits.tier)")
    }

    /// Local-only, synchronous — call after any wardrobe mutation
    /// (`AddItemViewModel.saveItem()`, `JobQueueStore.performUpload()`, item
    /// deletion) so point-of-use item counters stay live.
    func refreshItemCounts() {
        let inventory = (try? repository.fetchInventory()) ?? []
        coreItemCount = inventory.filter { $0.slot.isRequired }.count
        accessoryItemCount = inventory.filter { !$0.slot.isRequired }.count
    }

    /// Optimistic local debit, called immediately after a successful
    /// recommendation call — see file header. `refreshUsage()` reconciles
    /// with the server's real wallet on the next foreground/uid change.
    func recordRecommendationUsed() {
        guard recommendationCost > 0 else { return } // unmetered — nothing to debit
        recordSpend(operation: "RECOMMENDATION", cost: recommendationCost)
        AppLog.info(.viewModel, "UsageTracker.recordRecommendationUsed: creditsRemaining=\(self.creditsRemaining) (recommendations≈\(self.recommendationsRemaining))")
    }

    /// See `recordRecommendationUsed()`'s doc comment.
    func recordCombinationUsed() {
        recordSpend(operation: "IMAGE_GEN", cost: combinationCost)
        AppLog.info(.viewModel, "UsageTracker.recordCombinationUsed: creditsRemaining=\(self.creditsRemaining) (combinations≈\(self.combinationsRemaining))")
    }

    /// Debits `cost` credits from the local wallet, subscription bucket first
    /// then purchased (both floored at 0), and bumps this cycle's usage count
    /// — mirroring `backend/functions/src/middleware/creditGate.ts`'s debit
    /// order exactly. The server remains authoritative; this is only so the
    /// UI reflects the spend instantly instead of waiting on a Firestore
    /// round-trip.
    private func recordSpend(operation: String, cost: Int) {
        let current = currentCycleUsage()
        let fromSubscription = min(current.subscriptionCreditsRemaining, cost)
        let fromPurchased = min(current.purchasedCreditsRemaining, cost - fromSubscription)
        var counts = current.usageCounts
        counts[operation] = (counts[operation] ?? 0) + 1

        let updated = UsageDTO(
            tierId: current.tierId,
            subscriptionCreditsRemaining: max(0, current.subscriptionCreditsRemaining - fromSubscription),
            purchasedCreditsRemaining: max(0, current.purchasedCreditsRemaining - fromPurchased),
            usageCounts: counts,
            billingCycleStart: current.billingCycleStart
        )
        usage = updated
        if let uid = AuthService.shared.uid { Self.cacheUsage(updated, uid: uid) }
    }

    /// The wallet to apply an optimistic debit to. Three cases:
    ///  - A real, migrated credit doc still inside its billing cycle → use it.
    ///  - A migrated doc whose local billing anniversary has passed but the
    ///    server hasn't been re-fetched yet (offline across a monthly reset,
    ///    `autoReset` tiers only) → refill the subscription bucket to the tier
    ///    allocation and zero the counts, keeping purchased credits (lifetime,
    ///    never reset — matching `creditGate.ts`'s reset step).
    ///  - No migrated doc loaded (unmigrated legacy doc, cache miss) → seed
    ///    from the server-resolved `limits` so the bump has a balance to draw
    ///    from; reconciled on the next `refreshUsage()`.
    private func currentCycleUsage() -> UsageDTO {
        guard let usage, usage.tierId != nil else {
            return UsageDTO(
                tierId: limits.tier,
                subscriptionCreditsRemaining: limits.creditsRemaining ?? limits.creditAllocation ?? 0,
                purchasedCreditsRemaining: 0,
                usageCounts: [:],
                billingCycleStart: limits.billingCycleStart
            )
        }
        if let start = usage.billingCycleStart, limits.autoReset == true, Self.isCycleExpired(start) {
            return UsageDTO(
                tierId: usage.tierId,
                subscriptionCreditsRemaining: limits.creditAllocation ?? usage.subscriptionCreditsRemaining,
                purchasedCreditsRemaining: usage.purchasedCreditsRemaining,
                usageCounts: [:],
                billingCycleStart: Self.addUTCMonth(toEpochMs: start)
            )
        }
        return usage
    }

    /// True once `now` has passed the one-UTC-month anniversary of
    /// `billingCycleStartMs`. Mirrors `creditGate.ts`'s `addUTCMonths(_, 1)`
    /// boundary so a local optimistic bump never straddles a different cycle
    /// than the server's own reset.
    private static func isCycleExpired(_ billingCycleStartMs: Double) -> Bool {
        Date().timeIntervalSince1970 * 1000 >= addUTCMonth(toEpochMs: billingCycleStartMs)
    }

    /// Adds one UTC calendar month to an epoch-ms instant, matching
    /// `creditGate.ts`'s `addUTCMonths` (which clamps an overflowing
    /// day-of-month forward via `setUTCMonth`).
    private static func addUTCMonth(toEpochMs ms: Double) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = Date(timeIntervalSince1970: ms / 1000)
        let advanced = calendar.date(byAdding: .month, value: 1, to: date) ?? date
        return advanced.timeIntervalSince1970 * 1000
    }

    // MARK: - Disk cache (last-known-good usage, shown instantly on cold launch)

    private static func cacheKey(uid: String) -> String { "UsageTracker.cachedUsage.\(uid)" }

    private static func cacheUsage(_ usage: UsageDTO?, uid: String) {
        let key = cacheKey(uid: uid)
        guard let usage else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadCachedUsage(uid: String) -> UsageDTO? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(uid: uid)) else { return nil }
        return try? JSONDecoder().decode(UsageDTO.self, from: data)
    }
}
