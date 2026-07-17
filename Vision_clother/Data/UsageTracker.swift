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
//  `Domain/EntitlementLimits.swift.itemCap` and the existing pre-save
//  guards in `AddItemViewModel`/`JobQueueStore` already group slots.
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

    private let repository: WardrobeRepository
    private let syncService: WardrobeSyncService
    private var uidCancellable: AnyCancellable?

    /// Guards against an older, slower `refreshUsage()` call resolving after
    /// a newer one (or after an optimistic `record*Used()` bump) and
    /// clobbering good state — only the most-recently-*started* fetch's
    /// result is ever committed.
    private var refreshGeneration = 0

    init(repository: WardrobeRepository, syncService: WardrobeSyncService) {
        self.repository = repository
        self.syncService = syncService
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
    private var isAnonymous: Bool { isAnonymousQuota }

    var recommendationLimit: Int { EntitlementLimits.recommendationLimit(isAnonymous: isAnonymous) }
    var combinationLimit: Int { EntitlementLimits.tryOnLimit(isAnonymous: isAnonymous) }
    var recommendationsUsed: Int { usage?.recommendationCount ?? 0 }
    var combinationsUsed: Int { usage?.tryOnCount ?? 0 }
    var recommendationsRemaining: Int { max(0, recommendationLimit - recommendationsUsed) }
    var combinationsRemaining: Int { max(0, combinationLimit - combinationsUsed) }

    var coreItemCap: Int { EntitlementLimits.itemCap(for: .top, isAnonymous: isAnonymous) }
    var accessoryItemCap: Int { EntitlementLimits.itemCap(for: .accessory, isAnonymous: isAnonymous) }
    var isCoreItemCapReached: Bool { coreItemCount >= coreItemCap }
    var isAccessoryItemCapReached: Bool { accessoryItemCount >= accessoryItemCap }

    /// Best-effort read-through. A genuinely missing Firestore doc (`nil`
    /// return, no throw) is adopted as real "0 used" state. A *failed* fetch
    /// (network blip, permission-denied while a fresh ID token propagates,
    /// decode error, ...) intentionally leaves `usage` untouched — collapsing
    /// errors into `nil` previously made any transient failure look like the
    /// quota had reset to maximum, which is the bug this guards against.
    func refreshUsage() async {
        guard let uid = AuthService.shared.uid else { usage = nil; return }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let fetched = try await syncService.fetchUsage(uid: uid)
            guard generation == refreshGeneration else {
                AppLog.debug(.viewModel, "UsageTracker.refreshUsage: superseded by a newer refresh, discarding")
                return
            }
            usage = fetched
            Self.cacheUsage(fetched, uid: uid)
            AppLog.info(.viewModel, "UsageTracker.refreshUsage: recommendations=\(self.recommendationsUsed)/\(self.recommendationLimit) combinations=\(self.combinationsUsed)/\(self.combinationLimit)")
        } catch {
            AppLog.error(.viewModel, "UsageTracker.refreshUsage: fetch failed, keeping last-known usage — \(error.localizedDescription)")
        }
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
    func recordRecommendationUsed() {
        var current = currentPeriodUsage()
        current.recommendationCount += 1
        usage = current
        if let uid = AuthService.shared.uid { Self.cacheUsage(current, uid: uid) }
        AppLog.info(.viewModel, "UsageTracker.recordRecommendationUsed: now \(self.recommendationsUsed)/\(self.recommendationLimit)")
    }

    /// See `recordRecommendationUsed()`'s doc comment.
    func recordCombinationUsed() {
        var current = currentPeriodUsage()
        current.tryOnCount += 1
        usage = current
        if let uid = AuthService.shared.uid { Self.cacheUsage(current, uid: uid) }
        AppLog.info(.viewModel, "UsageTracker.recordCombinationUsed: now \(self.combinationsUsed)/\(self.combinationLimit)")
    }

    /// Returns the in-memory `usage` DTO if it's still within the current
    /// UTC month, or a fresh zeroed DTO otherwise — a stale DTO from a prior
    /// period must never keep accumulating optimistic increments, since the
    /// server's own counter has already rolled over (see
    /// `backend/functions/src/middleware/quota.ts`'s lazy `periodKey` reset).
    private func currentPeriodUsage() -> UsageDTO {
        let period = Self.currentPeriodKey()
        if let usage, usage.periodKey == period {
            return usage
        }
        return UsageDTO(periodKey: period, recommendationCount: 0, tryOnCount: 0)
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
