//
//  UsageTracker.swift
//  Vision_clother
//
//  Quota visibility feature (2026-07-17): the single live source of quota
//  state consumed by every point-of-use quota display/proactive-disable
//  (Add Item, Daily Assistant, Manual Pairing) and the Profile usage
//  summary (`Features/Profile/AccountSectionView.swift`). Enforcement
//  itself is unchanged and stays server-side
//  (`backend/functions/src/middleware/quota.ts` for recommendations/
//  try-ons, `backend/firestore.rules` for item counts) — this is purely a
//  client-side read model plus an optimistic local nudge so the UI can
//  decrement instantly on a successful call instead of waiting on a
//  Firestore round-trip.
//
//  "Combinations" (the user-facing term for a generated/rendered outfit
//  try-on) maps directly onto the existing `UsageDTO.tryOnCount` — there is
//  no separate backend counter for it.
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
    var isPremium: Bool { limits.tier == "premium" }

    var recommendationLimit: Int { limits.recommendationLimit }
    var combinationLimit: Int { limits.tryOnLimit }
    var recommendationsUsed: Int { usage?.recommendationCount ?? 0 }
    var combinationsUsed: Int { usage?.tryOnCount ?? 0 }
    var recommendationsRemaining: Int { max(0, recommendationLimit - recommendationsUsed) }
    var combinationsRemaining: Int { max(0, combinationLimit - combinationsUsed) }

    /// Lifetime StoreKit credit balances (`purchased*Balance` on the usage
    /// doc, granted via `Services/StoreKitPaymentManager.swift` →
    /// `backend/functions/src/routes/iapVerify.ts`). Standalone persistent
    /// values, fully decoupled from the monthly reset — see
    /// `currentPeriodUsage()`'s carry-forward.
    var purchasedRecommendationsRemaining: Int { usage?.purchasedRecommendationBalance ?? 0 }
    var purchasedCombinationsRemaining: Int { usage?.purchasedTryOnBalance ?? 0 }
    var totalRecommendationsRemaining: Int { recommendationsRemaining + purchasedRecommendationsRemaining }
    var totalCombinationsRemaining: Int { combinationsRemaining + purchasedCombinationsRemaining }

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

        AppLog.info(.viewModel, "UsageTracker.refreshUsage: recommendations=\(self.recommendationsUsed)/\(self.recommendationLimit) combinations=\(self.combinationsUsed)/\(self.combinationLimit) tier=\(self.limits.tier)")
    }

    /// Local-only, synchronous — call after any wardrobe mutation
    /// (`AddItemViewModel.saveItem()`, `JobQueueStore.performUpload()`, item
    /// deletion) so point-of-use item counters stay live.
    func refreshItemCounts() {
        let inventory = (try? repository.fetchInventory()) ?? []
        coreItemCount = inventory.filter { $0.slot.isRequired }.count
        accessoryItemCount = inventory.filter { !$0.slot.isRequired }.count
    }

    /// Optimistic local increment, called immediately after a successful
    /// recommendation call — see file header. `refreshUsage()` reconciles
    /// with the server's real count on the next foreground/uid change.
    /// Mirrors the server's consumption order
    /// (`backend/functions/src/middleware/quota.ts`): the monthly free tier
    /// absorbs the use while under its limit; past it, the purchased balance
    /// is decremented instead (floored at 0 — the server is authoritative).
    func recordRecommendationUsed() {
        var current = currentPeriodUsage()
        if current.recommendationCount < recommendationLimit {
            current.recommendationCount += 1
        } else {
            current.purchasedRecommendationBalance = max(0, (current.purchasedRecommendationBalance ?? 0) - 1)
        }
        usage = current
        if let uid = AuthService.shared.uid { Self.cacheUsage(current, uid: uid) }
        AppLog.info(.viewModel, "UsageTracker.recordRecommendationUsed: now \(self.recommendationsUsed)/\(self.recommendationLimit) purchased=\(self.purchasedRecommendationsRemaining)")
    }

    /// See `recordRecommendationUsed()`'s doc comment.
    func recordCombinationUsed() {
        var current = currentPeriodUsage()
        if current.tryOnCount < combinationLimit {
            current.tryOnCount += 1
        } else {
            current.purchasedTryOnBalance = max(0, (current.purchasedTryOnBalance ?? 0) - 1)
        }
        usage = current
        if let uid = AuthService.shared.uid { Self.cacheUsage(current, uid: uid) }
        AppLog.info(.viewModel, "UsageTracker.recordCombinationUsed: now \(self.combinationsUsed)/\(self.combinationLimit) purchased=\(self.purchasedCombinationsRemaining)")
    }

    /// Returns the in-memory `usage` DTO if it's still within the current
    /// UTC month, or a DTO with zeroed *counts* otherwise — a stale DTO from
    /// a prior period must never keep accumulating optimistic increments,
    /// since the server's own counter has already rolled over (see
    /// `backend/functions/src/middleware/quota.ts`'s lazy `periodKey` reset).
    /// The purchased balances are lifetime values with no relationship to
    /// the calendar and are always carried through the rollover — zeroing
    /// them here (e.g. on an offline launch in a new month) would make paid
    /// credits vanish from the UI until the next successful server fetch.
    private func currentPeriodUsage() -> UsageDTO {
        let period = Self.currentPeriodKey()
        if let usage, usage.periodKey == period {
            return usage
        }
        return UsageDTO(
            periodKey: period,
            recommendationCount: 0,
            tryOnCount: 0,
            purchasedRecommendationBalance: usage?.purchasedRecommendationBalance,
            purchasedTryOnBalance: usage?.purchasedTryOnBalance
        )
    }

    /// Matches `backend/functions/src/middleware/quota.ts`'s `periodKey()`
    /// (UTC `YYYY-MM`) so an optimistic local bump never straddles a
    /// different month boundary than the server's own counter.
    private static func currentPeriodKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
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
