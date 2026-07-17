# Timeline

History of features and fixes, newest first. Kept up to date per `CLAUDE.md` §6 so a future session can see what shipped and why without re-deriving it from `git log`.

## 2026-07-17 — Fix: Duplicate `ForEach` ID warning in `ProfileView`'s "Best Pairings" list

**Status:** Fixed, build verified (`xcodebuild clean build` — BUILD SUCCEEDED).

Non-fatal console warning: `ForEach<...>: the ID ... occurs multiple times ... undefined results`. `ProfileView.swift`'s "Best Pairings" section keyed its `ForEach` off `\.itemA.id`, but the same wardrobe item can appear as `itemA` across multiple top pairs (paired with different partners), colliding two rows on the same `UUID`. Switched to keying by array offset (`Array(pairs.prefix(5).enumerated())`, `id: \.offset`), matching the pattern this same file already uses for its other non-`Identifiable` derived collections (`tasteSignals`, `buckets`).

## 2026-07-17 — Fix: Concurrent Cloud Sync passes racing on the same pulled `WardrobeItem` rows

**Status:** Fixed, build verified (`xcodebuild clean build` — BUILD SUCCEEDED).

Same crash as the entry below recurred after that fix, but this time the logs showed duplicated `pullChanges: starting`/`ok items=1` lines at the same instant. Root cause: no reentrancy guard existed across `WardrobeSyncCoordinator`'s entry points — the `AuthService.$uid` Combine subscription (delivers immediately on subscribe, i.e. at coordinator `init`) calls `handleUIDChange` → `handleSignIn`, while `Vision_clotherApp.swift`'s `scenePhase → .active` hook independently calls `reconcileIfSignedIn` → `reconcile`. At launch with an already-signed-in user both fire near-simultaneously and land two overlapping `pullAndApply` passes that each independently delete-and-reinsert the same pulled row, compounding the stale-reference crash below.

Added an `isSyncOperationInFlight` gate (`runExclusiveSyncOperation`) wrapping `reconcileIfSignedIn`/`retrySync`/`handleUIDChange` so only one sync pass runs at a time.

## 2026-07-17 — Fix: Crash reading `WardrobeItem.slot` after a Cloud Sync pull ("backing data detached from context")

**Status:** Fixed, build verified (`xcodebuild clean build` — BUILD SUCCEEDED).

User hit a fatal crash (`SwiftData/BackingData.swift:249`) reading `WardrobeItem.slot` right after a Cloud Sync pull applied a changed item and a Daily Assistant recommendation call completed. Traced it: `WardrobeSyncCoordinator.applyWardrobeItemChange` (and every sibling `apply*Change`) applies a pull by deleting the existing row and inserting a fresh model instance with the same id, rather than mutating in place — so any previously-fetched Swift reference to the old object is left pointing at a deleted row. `DailyAssistantViewModel.wardrobeSnapshot()`'s `inventoryCache` exists specifically to be invalidated by `WardrobeMutationTracker.shared.markMutated()` on any wardrobe change, but `WardrobeSyncCoordinator` never called it from either the pull path (`pullAndApply`) or the account-switch wipe (`wipeLocalMirror`) — only `WardrobeRepository.save/update/delete` did. Confirmed this was a pre-existing bug, not caused by the same-day performance-audit changes, before fixing.

Added `WardrobeMutationTracker.shared.markMutated()` calls in `WardrobeSyncCoordinator.swift`: in `pullAndApply` (gated on the pull actually touching a `WardrobeItem`), and unconditionally in `wipeLocalMirror`.

## 2026-07-17 — Perf: Data-Scaling Audit (Power-User Closet/History Growth)

**Status:** Fixed, build verified (`xcodebuild clean build` — BUILD SUCCEEDED).

Requested a comprehensive audit for hidden data-scaling bottlenecks so the app stays smooth as a power user accumulates thousands of wardrobe items/combinations/impressions and years of feedback history, even though everything is fine at today's demo scale. Ran three parallel sweeps (SwiftData query bloat, synchronous I/O/crypto in serial paths, view-body/collection-algorithm/retain-cycle patterns), producing 9 findings fixed in priority order. See `timeline/TIMELINE.md`'s matching entry for the full file-by-file breakdown; summary:

- **Image loading (8 views):** synchronous `UIImage(contentsOfFile:)` on every grid-cell re-render replaced with a shared `CachedWardrobeImage` view backed by a bounded `NSCache` + off-main-actor decode in `ImageStorage.cachedImage(for:)`.
- **`WardrobeSyncCoordinator.pushEverythingLocal`:** the 5 full-table bootstrap-sync fetches (worst: `SwipeEvent`) were batched (500 rows/`Task.yield()`) rather than time-windowed — a time predicate would have silently dropped history the bootstrap is specifically supposed to push.
- **`ClosetView.displayItems`:** was recomputed 7x per render (once per slot); hoisted to once per `body`.
- **Query bounds:** `ProfileView.itemRatings` (used only for an `.isEmpty` check) became a `fetchLimit: 1` query; `outfitFeedbacks` was deliberately left unbounded since its stats are genuine all-time aggregates with no cheaper query shape — capping it would have been a correctness bug, not a fix. `CombinationsView`/`CombinationDetailView` capped to the most recent 300 saved combos. `fetchFeedbackHistory()`'s `SavedCombination` fetch narrowed from the full table to exactly the ids referenced by the (already time-windowed) `outfitFeedbacks`.
- **`ItemRatingScoring`:** added a batch `scores(for:history:)` that folds pair-feedback once instead of rescanning it per item per cell.
- **`JobQueueStore`:** thumbnails downscaled at enqueue time instead of retaining full-resolution originals forever; `jobs` capped at 200 with oldest-terminal-first eviction (in-flight jobs protected).
- **`AddItemView`/`SyncOutboxWorker`:** per-photo SHA256 hashing moved off the main actor; outbox drain now fans out up to 5 concurrent pushes instead of one at a time.
- **`RecommendationImpressionEvent`:** added a 90-day retention prune — the table had no reader and no prune, pure unbounded growth.

Deferred as follow-ups (out of scope for this low-risk pass): `Job.kind`'s retained payload bytes aren't cleared post-success (would need `Job`/payload structs to become mutable); no "load more" pagination UI was built for `CombinationsView`'s 300-item cap.

## 2026-07-17 — Fix: Data/CLAUDE.md's "never imports Domain/" rule contradicted actual repository code

**Status:** Fixed, build verified (simulator).

A review flagged that `Data/CLAUDE.md` stated "This layer never imports `Domain/` — they are peers, not dependencies," but `SwiftDataWardrobeRepository` (`Data/WardrobeRepository.swift`) has always called into `Domain/`: `fetchFeedbackHistory()` builds `AttributePreferenceProfile`/`RatedAttributes`/`OutfitDimensionRatedAttributes`/`ItemAttributeSnapshot`/`VisualPreferenceProfile`, and `applyImplicitSwipe`/`recordSwipe` call `VisualClusterUpdater.update`; several functions also log via `Domain/MLLog.swift` — whose own doc comment already acknowledges this exact dependency as intentional. So the doc rule was stale, not the code.

Considered two fixes: (a) update the doc to state the truth, or (b) actually split the Domain aggregation out of the repository into a separate builder called from the view-model layer. Went with (a) — a real split would touch the `WardrobeRepository` protocol and all 4 call sites (`ProfileViewModel`, `DailyAssistantViewModel`, and two Views — `ItemDetailView`/`ClosetView` — that have no view model today and would need one), plus rework the write paths (`applyImplicitSwipe`/`recordSwipe`) that currently compute-then-persist `VisualClusterUpdater` output in one pass. That's a much larger, riskier change than the actual problem warranted.

Replaced `Data/CLAUDE.md`'s line 7 with a rule that documents `SwiftDataWardrobeRepository`'s `fetchFeedbackHistory`/`applyImplicitSwipe`/`recordSwipe` as a sanctioned, scoped exception, pointing to `Domain/MLLog.swift`'s doc comment for rationale and explicitly warning against adding further Domain/ coupling elsewhere in `Data/` without discussion. Documentation-only change — no Swift source touched. `xcodebuild clean build` passes.

## 2026-07-17 — Feature: End-to-End Diagnostic Logging (iOS + Backend)

**Status:** Done, build verified (simulator). Backend TypeScript changes were not compiled/tested in this session (user instruction: implement only, no `npm`/`tsc` runs) — read carefully against neighboring code instead.

Goal: instrument every major step of the app — auth, Cloud Sync, every network call, the recommendation pipeline, and user-triggered ViewModel actions — thoroughly enough that a pasted log excerpt is enough to diagnose a bug in under a minute, without needing a live debugging session.

Landed in four phases, build-verified after each:

1. **Shared logging infra:** new `Vision_clother/Diagnostics/AppLog.swift` (a `Category`-tagged `os.Logger` wrapper: `.auth`/`.sync`/`.network`/`.recommendation`/`.tryOn`/`.vision`/`.jobQueue`/`.viewModel`/`.app`, all under the existing `com.visionclother` subsystem `Domain/MLLog.swift`/`Services/PerfLog.swift` already use) and `Vision_clother/Diagnostics/DebugLogStore.swift` (an actor mirroring every `AppLog` line to a size-capped rotating file under the caches directory). `AccountSectionView` (Profile tab) gained a "Share Debug Log"/"Clear Debug Log" row so a user can hand over a bug report with no Mac/Xcode session. Backend gained `backend/functions/src/logger.ts`, a thin wrapper over `firebase-functions/logger` for structured (severity-aware) Cloud Logging instead of plain `console.*`.
2. **Auth/Sync/Network:** `AuthService` logs every sign-in/link/sign-out transition and outcome (uid, never tokens); `ProxyAuthHeaders.current()` mints a short `X-Request-Id` per proxied call (the join key between an iOS `AppLog` line and the matching backend Cloud Logging line for the same request); every OpenRouter/Pexels-calling service (`OpenRouterIntentExtractionService`, `OutfitRecommendationService`, `OpenRouterTryOnRenderService`, `VisionMetadataExtractionService`, `StockImageFeedService`, `UserProfileDerivationService`) logs request start/outcome/latency; `SyncOutboxWorker`/`SyncingWardrobeRepository`/`WardrobeSyncCoordinator`/`WardrobeSyncService` log outbox drains, account-switch bootstrap/pull/wipe decisions, and photo upload/download outcomes. Backend: a new `app.ts` request-logging middleware mints/echoes `X-Request-Id` and logs method/status/duration for every request; `verifyAuth`/`rateLimit`/`quota` middleware and all three proxy routes log their gate outcomes and upstream status.
3. **Recommendation pipeline:** `DailyAssistantViewModel` now calls `OutfitRecommendationValidator.validateVerbose` (previously computed but never consumed) and logs a kept-count + rejection-reason histogram through `MLLog` — directly answers "why did the LLM path yield fewer/zero outfits." `WardrobeCatalogBuilder.build` logs a per-call summary (inventory size, ghost-excluded count, final catalog size, prospective-item presence).
4. **ViewModel actions:** `AddItemViewModel`, `CombinationsViewModel`, `JobQueueStore` (upload + try-on job lifecycle), `ManualPairingViewModel`, `ProfileViewModel`, `RateCombinationViewModel`, `RateItemViewModel`, `SwipeDiscoveryViewModel`, and `StyleCheckViewModel` each log their user-triggered actions' start/success-summary/failure-detail through `AppLog`'s `.viewModel`/`.jobQueue` categories.

Redaction rule enforced throughout: never log ID tokens, API keys, base64 image payloads, or full LLM prompt/response bodies — only lengths, ids, status codes, and counts. `docs/approach/conventions.md` gained a short "Diagnostics/Logging" section documenting this convention for future code.

## 2026-07-17 — Fix: Profile Photo & Daily Assistant Chat Didn't Reset on Account Switch; Closet Photos Landed Inconsistently

**Status:** Fixed, build verified (simulator).

Reported symptom: after switching accounts, the Profile tab's portrait photo and the Daily Assistant chat timeline kept showing the *previous* account's state — only the Closet tab actually reflected the newly signed-in account. Separately, even Closet items that did switch correctly showed their photo inconsistently: some appeared, some stayed stuck on the color-swatch placeholder.

Root cause, common to all three: `Data/WardrobeSyncCoordinator.swift` only resets state it explicitly owns — SwiftData rows and the `ImageStorage` photo directory. Anything else has no way to learn an account switch happened.

1. **Profile photo:** `Services/UserPortraitStorage.swift` stored the user's own photo under one fixed, device-wide filename — not account-scoped at all, and never touched by `wipeLocalMirror`. On top of that, `ProfileViewModel` only read it once, in `init()`, and `ProfileView` constructs that view model exactly once for the tab's lifetime (SwiftUI's plain `TabView` keeps every tab alive) — so even wiping the file wouldn't have helped without also telling the already-alive view model to re-read it.
2. **Chat timeline:** `DailyAssistantViewModel.rounds` is pure in-memory state with the same one-time-construction pattern — nothing ever told it the signed-in account changed, so it just kept showing whatever was already there.
3. **Inconsistent closet photos:** confirmed as a leftover consequence of the previous fix below (background photo prefetch, `downloadMissingPhotos`) — those downloads write straight to `ImageStorage` on disk, entirely outside SwiftData, so `@Query` never re-fires when a file lands. Whichever items had their file already downloaded by the very first grid draw looked right by luck; every other item stayed on the placeholder until an unrelated mutation forced SwiftUI to redraw the grid from scratch.

Fix, discussed and confirmed with the user via two explicit product decisions (portrait: sync to the cloud like other account data, not just wipe-on-switch; chat: reset to empty on switch, not persist/restore full history — persisting chat is out of scope, a future feature):

- **Portrait cloud sync** (new): `Services/WardrobeSyncService.swift` gained `uploadPortrait`/`downloadPortrait`/`fetchPortraitUpdatedAt`, storing bytes at `users/{uid}/portrait/base_portrait.jpg` (new `backend/storage.rules` block, mirroring the existing `wardrobeImages` one) with presence/timestamp tracked at `users/{uid}/meta/portrait` (already covered by the existing generic `meta/{metaDoc}` Firestore rule — no `firestore.rules` change needed). `ProfileViewModel.savePortrait` now best-effort uploads after a local save (same fire-and-forget posture as item photo uploads); `WardrobeSyncCoordinator.wipeLocalMirror` now also deletes the local portrait file on an account switch; bootstrap push (`uploadAllLocalPhotos`) now also pushes an existing local portrait for a brand-new account; the background photo prefetch (`downloadMissingPhotos`) now also fetches the portrait if missing locally.
- **Account-switch reactivity:** `ProfileView`/`DailyAssistantView` now observe `AuthService.shared.uid` directly (`@ObservedObject`) — on change, `DailyAssistant` calls its existing `resetConversation()`, `Profile` calls a new `ProfileViewModel.refreshPortrait()`.
- **Photo-refresh reactivity:** `WardrobeSyncCoordinator` gained a `photoRefreshTick` counter, bumped once per background-prefetch batch that actually wrote a file (items, combinations, or the portrait). `ClosetView`, `CombinationsView`, and `ProfileView` key their image-bearing containers off this tick so a background-downloaded photo actually triggers a redraw; `CombinationDetailView` keys just its per-page `image` view off it (not the whole `TabView`) so a photo landing mid-browse doesn't reset the user's swipe position.

`xcodebuild clean build` passes. `backend/storage.rules` was edited but not deployed — deploy separately when ready.

## 2026-07-16 — Fix: Item/Combination Photos Never Synced to Cloud Storage, Then Actively Deleted Locally by Sync

**Status:** Fixed, build verified (simulator).

Reported symptom: closet items rendered as their color swatch instead of the actual photo, and saved combinations showed "Couldn't load this image" — despite item metadata/recommendations still being correct. A companion SwiftData crash also surfaced: `Fatal error: This backing data was detached from a context without resolving attribute faults` on `SavedCombination.labelsBySlot`.

Root-caused to three compounding bugs, confirmed via the Firebase Console (Storage bucket had zero files despite every item pushing successfully to Firestore):

1. **Primary cause:** `Services/WardrobeSyncService.swift`'s `uploadImage` called `putDataAsync(data)` with no `StorageMetadata` — no `contentType` was ever set on the upload. `backend/storage.rules`' write rule requires `request.resource.contentType.matches('image/.*')`, so every single photo upload was silently rejected by the security rules (wrapped in `try?`, fire-and-forget, so nothing ever surfaced this). Fixed: added a `SyncImageContentType` enum (`.png`/`.jpeg`) threaded through `uploadImage(filename:data:contentType:uid:)`, and the real implementation now sets `StorageMetadata.contentType` explicitly. Both call sites (`Data/SyncingWardrobeRepository.swift`'s `uploadImageIfNeeded`, `Data/WardrobeSyncCoordinator.swift`'s `uploadAllLocalPhotos`) already knew PNG-for-items vs. JPEG-for-combinations and now pass it through.
2. **Amplifier:** `WardrobeSyncCoordinator.applyWardrobeItemChange`/`applySavedCombinationChange` unconditionally deleted the local on-disk photo (`ImageStorage.delete`) before reinserting the row on *any* pull/reconcile — not just account switches — trusting a background re-download to restore it. Combined with bug 1 (the re-download always failed, since nothing was ever actually uploaded), this actively destroyed working local photos during routine foreground syncing. Fixed: the local file is now only deleted when the incoming DTO's `imageAssetName` actually differs from what's already there.
3. **Crash:** `CombinationsViewModel` cached `combinations` as a manually-loaded `[SavedCombination]` snapshot (unlike `ClosetView`'s live `@Query`). If a pull's delete-and-reinsert (bug 2) fired while `CombinationDetailView` was open, the view kept referencing the now-deleted/detached model instance — the next property read (`.displayTitle` → `.labelsBySlot`) crashed with SwiftData's "backing data was detached from a context without resolving attribute faults" fatal error. Fixed: `CombinationsViewModel` no longer caches a list at all; `CombinationsView` and `CombinationDetailView` each hold their own live `@Query(sort: \SavedCombination.savedAt, order: .reverse)`, so a background mutation is reflected automatically instead of leaving a stale reference.

**Not recovered:** photos already lost locally before this fix (local file deleted by bug 2, cloud copy never existed per bug 1) have no remaining copy anywhere and need to be re-added manually — no backfill pass was added, per explicit instruction.

## 2026-07-16 — Fix: Wardrobe Data Still Vanished on Returning to a Prior Account (follow-on)

**Status:** Fixed, build verified (simulator).

Reported symptom: same shape as the "Wardrobe Data Erased on Account Switch" fix below, but surviving it — sign in as Account A, add items, sign out, sign in as Account B, add items, sign out, sign back into Account A: A's closet was completely empty, and repeating the sign-out/sign-in cycle didn't recover it. Confirmed via the Firebase Console that Account A's `wardrobeItems` documents were genuinely still present in Firestore — this was a pull-side bug, not data actually lost.

Root cause, in `Data/WardrobeSyncCoordinator.swift`'s `handleSignIn(uid:)`: `let remoteStatus = try? await syncService.fetchSyncStatus(uid: uid)` silently collapsed "the read failed" (plausible right after this app's rapid sign-out → new-anonymous-session → `credentialAlreadyInUse` → real-account-signIn sequence, before Firestore's client-side auth context has caught up) into the same `nil` as "this account genuinely has no cloud history yet." Since the local mirror had already been wiped for the outgoing account a few lines earlier, that misclassification sent a returning real account down the empty-bootstrap-push path, which then *overwrote* the account's real `syncStatus` doc with a fresh `hasCompletedInitialSync = true` watermark — masking the fact that nothing was actually pulled. Worse, `Self.currentMirrorUID = uid` was stamped unconditionally at the end of `handleSignIn`, even on this bad path, so the failure wasn't a one-off: every later switch back to that account took the "already mirrored" fast path (a delta reconcile off the bogus watermark) and never attempted a full pull again — permanent, not self-healing.

Fix: `fetchSyncStatusResilient(uid:)` retries the status check a few times before giving up, and a still-unresolved status (or a failed `fullPull`) now aborts the switch without stamping `currentMirrorUID` or touching `syncStatus` — leaving the account eligible for a real retry instead of being permanently marked "done." `reconcileIfSignedIn` (the existing foreground safety net) now re-attempts a full `handleSignIn` when `currentMirrorUID` doesn't match the signed-in uid, so a failed switch self-heals the next time the app foregrounds; a new `WardrobeSyncCoordinator.retrySync()` plus a `lastSyncError`-driven message and "Retry Sync" button in `AccountSectionView` let the user retry immediately instead of waiting. `xcodebuild clean build` passes.

## 2026-07-16 — Fix: Uploaded items always got the same placeholder description instead of a real vision-LLM tag

**Status:** Fixed, build verified (simulator).

Reported symptom: every uploaded garment's `description` (and, on inspection, its whole `GarmentMetadata`) came back identical regardless of the photo — the literal fixed string in `MockVisionMetadataExtractionService` ("Charcoal crewneck tee in a soft cotton blend."), confirming the mock was running in production instead of `OpenRouterVisionMetadataExtractionService`. Same root cause as the same-day "Account Section Showed Signed In With No Session" fix above: `ServiceFactory` decided mock-vs-real by reading `AuthService.shared.isSignedIn` once, at the moment each service was constructed, and callers (`Vision_clotherApp.init()`'s `JobQueueStore`, and several view-level view models) held that decision for their entire lifetime via `private let`. If `isSignedIn` read `false` at that one construction moment — which happens on every launch, not just the first, whenever the guest-first anonymous sign-in never actually succeeds (e.g. Anonymous auth disabled in the Firebase Console) — every subsequent call was permanently frozen on the mock, with no way for a later successful sign-in to un-stick it. `Services/WardrobeSyncService.swift`'s `AuthGatedWardrobeSyncService` had already solved exactly this for wardrobe sync (re-checking `isSignedIn` on every call instead of snapshotting), but the fix was never extended to the other five `ServiceFactory`-gated services.

Fix: added the same auth-gated, re-check-per-call wrapper for all remaining stale-snapshot services — `AuthGatedVisionMetadataExtractionService`, `AuthGatedIntentExtractionService`, `AuthGatedOutfitRecommendationService`, `AuthGatedTryOnRenderService`, `AuthGatedUserProfileDerivationService`, and `AuthGatedStockImageFeedService` — each living alongside its protocol/mock in its existing service file, and updated `ServiceFactory`'s six `make*` methods to return the wrapper unconditionally instead of a one-time ternary. No behavior change to the mock/real selection *logic* itself (still `AuthService.shared.isSignedIn`), only to *when* it's evaluated — every call now, not once at construction. `xcodebuild clean build` passes.

**Still needed (not a code fix):** same as above — confirm Anonymous sign-in is enabled for the Firebase project, since a real `isSignedIn == false` (as opposed to a stale snapshot of a since-changed `true`) still correctly routes to the mock by design; this fix only prevents a *correct* later `true` from being ignored.

## 2026-07-16 — Fix: Account Section Showed "Signed In" With No Session

**Status:** Fixed, build verified (simulator).

Reported symptom: a fresh device showed "Signed in" with a Sign Out button despite never signing in, the Sign Out button did nothing, and every AI feature was silently non-functional. Root cause: `AccountSectionView`'s guest/linked branch keyed off `AuthService.isAnonymous` alone, which defaults to `false` both for a real linked account *and* for no Firebase session at all (`Auth.auth().currentUser?.isAnonymous ?? false`). If the guest-first anonymous sign-in (`AuthService.ensureGuestSession()`, fired from `init()`) never succeeds — most likely because Anonymous sign-in isn't enabled in the Firebase Console for the `visionclother` project — `isSignedIn` and `isAnonymous` both read `false`, and the view fell into the "linked/signed-in" branch instead of a real empty state. That made Sign Out a no-op (`WardrobeSyncCoordinator.performExplicitSignOut()` guards on `AuthService.shared.uid`, which was `nil`) and left `ServiceFactory` permanently on Mock services (gated on `isSignedIn`) with no visible explanation.

Fix: `AccountSectionView` is now genuinely three-state — linked (`isSignedIn && !isAnonymous`), guest (`isSignedIn && isAnonymous`), and a new **no-session** state (`!isSignedIn`) with a visible error message and a manual "Retry" button. `AuthService.ensureGuestSession()` no longer swallows its `signInAnonymously()` failure via `try?` — it now captures the error into a new published `guestSessionError` so the no-session UI can display *why* (e.g. surfaces "This operation is restricted..." if Anonymous auth is disabled server-side).

**Still needed (not a code fix):** confirm Anonymous sign-in is enabled for the Firebase project at Authentication → Sign-in method → Anonymous in the Firebase Console — the app-side fix only makes the failure visible/retryable, it can't enable the provider itself.

## 2026-07-16 — Feature: Guest-First Auth + Tiered Usage Quotas

**Status:** Implemented, build verification pending this pass.

Follow-on to the account-switch data-loss fix below, per the plan drafted this session (project memory: guest auth + quota plan). Moves Vision Clother from "sign-in optional, AI features gated behind it" to guest-first: every install gets a working AI-powered app immediately via a Firebase Anonymous session (`Services/AuthService.swift`'s `ensureGuestSession()`, kicked from `init`), no sign-in wall. Signing in (Google/phone) now *links* the anonymous identity (`AuthService.signInOrLink`, falling back to a plain sign-in on `credentialAlreadyInUse`) rather than replacing it — raising limits and surviving reinstall, not unlocking recommendations outright — except try-on rendering, which still requires a linked account.

**Backend (route split + quota middleware):** `backend/functions/src/routes/openrouterChat.ts` was a single generic pass-through serving recommendations, vision-tagging, profile derivation, and try-on alike. New `backend/functions/src/middleware/quota.ts`'s `quotaGate(feature:)` (mirrors `rateLimit.ts`'s per-day Firestore-transaction shape, at monthly granularity) now gates two new dedicated routes — `/openrouter/recommend` and `/openrouter/tryon` (`backend/functions/src/app.ts`) — against `users/{uid}/meta/usage`, with tier resolved from `verifyAuth.ts`'s new `req.isAnonymous` (from the decoded token's `firebase.sign_in_provider`) and `users/{uid}/meta/entitlement` (defaults to "free"; "premium" is an unimplemented extensibility hook — TIER_LIMITS omits it, so it 403s rather than silently going unlimited). Guest: 20 recommendations/month, 0 try-ons (403 `sign_in_required`, distinct from a 429 `quota_exceeded`). Free: 100/10. Vision-tagging/profile-derivation/intent-extraction/background-isolation stay on the original uncapped `/openrouter/chat`. Client (`Config/ProxyConfig.swift`, `Services/OutfitRecommendationService.swift`, `Vision_clother/Services/OpenRouterTryOnRenderService.swift`) points at the new routes and surfaces `.quotaExceeded`/`.signInRequired` distinctly.

**Item-count caps:** `Domain/EntitlementLimits.swift` (5/2 guest, 10/4 signed-in, core-vs-accessory split by `Slot.isRequired`) is the client pre-check, called from `AddItemViewModel.saveItem()` and `JobQueueStore.performUpload()` before `repository.save`. Server backstop: `backend/firestore.rules`' `wardrobeItems` create rule checks a new `users/{uid}/meta/itemCounts` doc against the same caps; `Services/WardrobeSyncService.swift`'s `adjustItemCount(slot:delta:uid:)` (best-effort, fire-and-forget from `Data/SyncingWardrobeRepository.swift`'s `save`/`delete`) maintains that counter. Known, documented gap (mirrors the rules file's own limitation note): the counter isn't transactionally atomic with the item write, and re-slotting an item via `EditItemView` isn't tracked — a scheduled reconciliation function is the recommended real fix, not implemented here.

**Guest-first auth:** `Data/WardrobeSyncCoordinator.swift`'s new `performExplicitSignOut()` reverses the prior "sign-out doesn't erase your closet" contract from the fix below — guest-first means there's no true signed-out state anymore, so sign-out now drains the outbox, wipes the local mirror, and immediately starts a fresh anonymous session (reusing the already-shipped `isSyncingAccountSwitch` indicator). `Vision_clother/Features/Profile/AccountSectionView.swift` is now three-state: guest (sign-in buttons that transparently link), linked (existing signed-in content), and a read-only usage readout (`WardrobeSyncService.fetchUsage(uid:)` reads `meta/usage`, limits mirrored for display in `EntitlementLimits.recommendationLimit`/`tryOnLimit`). `Vision_clother/Features/DailyAssistant/DailyAssistantView.swift`'s "How does it look on me?" trigger gained a guest guard (alert, same pattern as the existing missing-portrait guard) ahead of the backend's own 403.

**Out of scope (per the plan):** actual premium/StoreKit implementation — only the `meta/entitlement` doc and `TIER_LIMITS`'s shape exist so premium is a data change later, not a re-architecture.

## 2026-07-16 — Fix: Wardrobe Data Erased on Account Switch

**Status:** Fixed, build verified.

Reported symptom: sign in, add wardrobe items, switch to a different Firebase account, switch back — the original account's data (including everything previously synced, not just the new items) was completely gone. Root-caused to three compounding bugs, all in the Cloud Sync layer (`docs/decisions/resolved-v1.md`'s "Cloud Sync" section):

1. **Primary cause, matches the exact repro:** `ServiceFactory.makeWardrobeSyncService()` snapshotted `AuthService.shared.isSignedIn` once. `Vision_clotherApp.init()` calls it exactly once at launch to build the app-root `WardrobeSyncCoordinator` and the `SyncingWardrobeRepository` feeding `JobQueueStore`. A cold launch while signed out (the normal/default state) permanently froze both on `MockWardrobeSyncService` — a silent no-op — for the rest of the process's life, even after a later sign-in. Fixed with `AuthGatedWardrobeSyncService` (`Services/WardrobeSyncService.swift`), a router that re-checks `isSignedIn` on every call instead of baking the choice in at construction time; `ServiceFactory.makeWardrobeSyncService()` now returns it unconditionally.
2. `WardrobeSyncCoordinator.wipeLocalMirror()` ran unconditionally on any different-uid sign-in with no check that the outgoing account's dirty `SyncMetadata` rows had actually finished pushing (per-mutation pushes are fire-and-forget). Fixed: `wipeLocalMirror` is now `async` and races a bounded (~5s) outbox drain for the outgoing account before wiping — best-effort, proceeds either way so an offline user can still switch accounts.
3. `pushEverythingLocal` (bootstrap push on first sign-in) wrapped every push in `try?` and unconditionally stamped `hasCompletedInitialSync = true` regardless of actual success, with no retry record for a partial failure. Fixed: bootstrap pushes now route through the same durable `SyncMetadata` outbox ordinary mutations use (`SyncOutboxWorker.drainNow` now returns `Bool`), and `initializeSyncStatus` is only called when that drain confirms zero dirty rows remain.

Also added a brief "Syncing your closet…" indicator (`WardrobeSyncCoordinator` is now `@Observable`, exposing `isSyncingAccountSwitch`, wired via `.environment(syncCoordinator)`) shown in `AccountSectionView` during an account switch, so the switch visibly waits instead of looking instant while sync happens invisibly.

Deferred to a separate follow-on (see project memory, not yet planned in this repo's docs): a guest-first anonymous-auth redesign and a tiered usage-quota/entitlement system, which also requires splitting the backend's generic OpenRouter proxy route by feature.

## 2026-07-15 — Feature: Multi-Accessory Outfits

**Status:** Implemented (build verified; test target not run this pass per user instruction).

Closes the last of three deferred items in `docs/decisions/stylist-intelligence-engine.md`: an outfit could only ever carry one accent item. Investigation found cross-slot accessorizing (bag + headwear + accessory) already worked — `Slot` already has three independent accent cases — the actual gap was the single `.accessory` slot being an explicit catch-all ("belt, scarf, tie, watch, or sunglasses... one per outfit, not several simultaneously"), so "belt + jewelry" collided. Fix: the primary `.accessory` slot is untouched (zero risk to existing behavior/tests); a small, bounded **supplementary accessories** list (max 2, `FashionKnowledgeConstants.DressCode.maxSupplementaryAccessories`) was added as a wholly separate, additive field at every layer — not a rewrite of the `[Slot: WardrobeItem]` dictionary every other slot uses.

Threaded through: `RecommendedOutfitWire.supplementaryAccessoryIDs` (wire, via the same dynamic-key `Codable` container under a fixed `supplementary_accessory_ids` key), the JSON schema (new array property, `maxItems` capped), `OutfitRecommendationValidator` (one explicit resolution step alongside, not inside, the existing per-slot loop — extends the duplicate-id check, caps/truncates rather than rejecting on overflow), `OutfitCombination.supplementaryAccessories` (folded into `items`), `StylistBrain`'s prompt (business/interview/formal must leave it empty; casual/going-out may use up to the cap), `SavedCombination.supplementaryAccessoryItemIDs`/`Labels` (new `SchemaV8`, additive), `OutfitCardView` (one row per supplementary accessory), and `JobQueueStore.saveCombination`/`CombinationsViewModel.resolveItems` (both integration points that build/resolve a `SavedCombination`).

## 2026-07-15 — Feature: "What Would You Change?" Checklist (Level 3 Outfit Feedback)

**Status:** Implemented (build verified; test target not run this pass per user instruction).

Closes the second of three deferred items in `docs/decisions/stylist-intelligence-engine.md`: Level 1/2 dimension-based outfit feedback shipped, but the structured "what specifically was wrong" checklist was scoped and never built. No prior spec existed anywhere in the repo for the actual checklist options, so this defines seven fresh, each mapped 1:1 onto an existing (or newly-fed) affinity dimension in `Domain/AttributePreferenceProfile.swift`: Too Formal/Too Casual → `formalityAffinity` (mutually exclusive), Wrong Colors → `colorVibeAffinity`, Wrong Pattern → `patternAffinity` (a new outfit-level entry point — previously only item-level `ItemRating.patternLike` fed this map), Not My Style → `styleTagAffinity`, Didn't Fit Right → `silhouetteAffinity`, Wrong For The Weather → `fabricWeightAffinity`. A flagged reason clamps that dimension's contribution to a strongly negative value (`min(existing, 0.1)`) regardless of the Level 2 star given — a deliberate signal layered on top of, not a replacement for, the star.

New `Models/FeedbackEvent.swift`'s `OutfitChangeReason` enum + `OutfitFeedback.changeReasonsRaw`; `OutfitDimensionRatedAttributes` gained `pattern`/`patternDissatisfaction`; `Data/WardrobeRepository.swift`'s `fetchFeedbackHistory()` applies the clamp per flagged reason when building the per-item dimension join. UI: a new "What Would You Change?" checklist section in `Features/Rating/RateCombinationView.swift`, backed by `RateCombinationViewModel.toggleChangeReason`. New `SchemaV7` (additive `[String]` column, `.lightweight` migration).

## 2026-07-15 — Feature: Impression/Selection Event Capture

**Status:** Implemented (build verified; test target not run this pass per user instruction).

Closes the first of three deferred items in `docs/decisions/stylist-intelligence-engine.md`'s Deferred section: the app logged ML drift (`[AI-Stylist-ML]`) but never recorded which of several shown candidate outfits the user actually acted on vs. ignored. A new event-sourced `Models/RecommendationImpressionEvent.swift` (mirrors `SwipeEvent`'s shape) gets one row per candidate the moment `DailyAssistantViewModel.sendTurn` resolves a successful round (`rank` = position in the LLM's strongest-to-weakest sort, `id` = the in-memory `OutfitCombination.id`); `startTryOn` — the concrete "pick" gesture among the shown candidates — marks that row's `selectedAt`. `Data/WardrobeRepository.swift` gained `recordImpressions`/`recordSelection`, both best-effort (`try?`) and logged under the existing `[AI-Stylist-ML]` tag. New `SchemaV6` (purely additive new table, `.lightweight` migration). Not wired into any ranker this phase — same posture as `OutfitRecommendationValidator.RejectionReason`, this just makes the data exist for a future investigation.

## 2026-07-15 — Fixed: "How does it look on me?" failed with "Render failed: Invalid image data-url"

**Status:** Fixed.

Tapping "How does it look on me?" on a Daily Assistant recommendation failed downstream at the OpenRouter render API with an opaque `"Invalid image data-url"` error whenever the user hadn't captured a portrait photo yet (via the Profile tab). Root cause: `DailyAssistantView.swift`'s `placeholderBaseImageData` fell back to empty `Data()` when `UserPortraitStorage.load()` returned `nil`, which base64-encoded to an empty `data:image/png;base64,` string that OpenRouter rejected — a known, previously-commented gap, not a regression. `ManualPairingView`/`ManualPairingViewModel` already guard this identical precondition (`UserPortraitStorage.exists` → "Add a photo of yourself first."); Daily Assistant's try-on button never got the equivalent check. Added the same guard at the button-tap call site: `onStartTryOn` now checks `UserPortraitStorage.exists` before enqueuing the job and shows an alert ("Add a photo of yourself on your Profile tab to try on outfits.") instead of ever sending empty image data. `xcodebuild` clean build passes.

## 2026-07-15 — Swipe-to-Learn calibration meter + `[AI-Stylist-ML]` verification logging

**Status:** Implemented.

A `/new_feature` request asked for the on-device Vision-embedding/k-means visual-taste pipeline to be built from scratch, with an exact formula spec. Investigation (see `docs/decisions/stylist-intelligence-engine.md`'s new 2026-07-15 entry) found the entire pipeline already shipped in the two entries below, matching the spec's numbers almost exactly. Confirmed with the user to keep the existing, documented cosine-similarity/incremental-mean math unchanged rather than rewrite it to match two spec details that diverged (Euclidean nearest-centroid, fixed η=0.10) — and to skip an Accelerate/vDSP rewrite of the already-tested pure-Swift vector math.

What was genuinely new: `VisualClusterUpdater.update` (`Domain/VisualPreferenceProfile.swift`) now returns each nudge's drift percentage; `VisualPreferenceState` (`Models/SwipeDiscovery.swift`) gained `totalSwipes`, `calibrationProgress` (linear 0...1 over 20 explicit swipes), and `isTrained`; `Data/WardrobeRepository.swift` increments `totalSwipes` and logs drift/calibration-complete under a new `[AI-Stylist-ML]` tag (`Domain/MLLog.swift`), and `Domain/WardrobeCatalogBuilder.swift`'s `rank(_:history:)` logs each item's visual affinity bonus while ranking. The swipe-deck screen (`Features/SwipeDiscovery/`) now shows a minimalist Activity-ring-style "Stylist Calibration" meter (`CalibrationRingView.swift`, new) that animates toward a checkmark badge at 100% rather than exposing a raw percentage/log readout.

## 2026-07-15 — Item Rating question redesign + Swipe-to-Learn implicit swipe bridge

**Status:** Implemented.

User feedback: the per-item rating form's questions (Confidence, Versatility, Predicted Wear Frequency, Quality Perception) read as generic and out of scope. Root cause traced to `Domain/AttributePreferenceProfile.swift`: every answer was averaged into one blended `ItemRating.normalizedValue`, then that single number was reused as the signal for color/pattern/formality affinity alike — with no dedicated color or pattern question ever asked, despite `colorVibeAffinity`/`patternAffinity` maps already existing.

`Models/ItemRating.swift`'s question set is now Fit, Comfort, Color ("do you like this color on you?"), Pattern (skipped for solid-pattern items), Formality Fit ("did this feel right for how formal/casual you needed it?"), Style Identity, Wear Again — each mapped 1:1 to its own affinity in `RatedAttributes` instead of one blended value. `fit.centeredness` and `comfort` now also feed item-level `silhouetteAffinity`/`fabricWeightAffinity`, closing a gap where those two dimensions previously had no item-level signal at all. Clean-break schema change (no shipped users).

Second change, requested alongside the rating redesign: item ratings now feed the Swipe-to-Learn visual taste system (`Features/SwipeDiscovery/`). A highly-rated item is treated as an implicit "swipe right" on its cached photo embedding (a poorly-rated one an implicit "swipe left"), nudging the same k-means centroids the discovery deck writes — via a new `Data/WardrobeRepository.swift`'s `applyImplicitSwipe`, called from `recordItemRating`. `VisualClusterUpdater.update` gained an optional `learningRate` parameter so implicit (rating-derived) nudges use a gentler fixed step (`implicitLearningRate = 0.05`) than the existing explicit-swipe incremental-mean step, which is unchanged. Implicit swipes are best-effort (no-op if the item has no cached embedding yet) and don't write a `SwipeEvent` — see `docs/decisions/stylist-intelligence-engine.md` for the full design.

## 2026-07-14 — Fix: Try-On Button Allows Duplicate Queue Submissions

**Status:** ✅ Shipped — Build Succeeded

### Problem
After tapping "How does it look on me?", the button showed "Added to queue" for 1.5 seconds then reset back to the original label — letting the user submit the same outfit combination to the try-on queue multiple times.

### Fix
Replaced `justQueuedTryOn: Bool` + `Task.sleep` reset with `queuedOutfitIDs: Set<OutfitCombination.ID>`. Each outfit's queued state is now **permanent and per-outfit**:
- Once queued, the button stays locked as "Added to queue ✓" for that outfit forever
- Swiping to a different (unqueued) outfit shows a fresh active button for that card
- Swiping back to an already-queued outfit keeps it locked — no re-submission possible

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | Replaced `@State var justQueuedTryOn: Bool` + `Task.sleep` reset with `@State var queuedOutfitIDs: Set<OutfitCombination.ID>`; removed the Task entirely |

---

## 2026-07-14 — Fix: Outfit Carousel Unswipeable + Screen Scroll Frozen

**Status:** ✅ Shipped — Build Succeeded

### Problem
After the previous UX pass, the outfit recommendation carousel was completely unswipeable and tapping anywhere inside the card area froze the entire screen's vertical scroll. Root cause was a three-layer gesture conflict:

```
ScrollView (vertical)   ← outer chat timeline
  └── TabView(.page)    ← UIKit page controller stealing horizontal drags
       └── OutfitCardView
            └── ScrollView (vertical)  ← inner scroll competing with outer
```

The `TabView(.page)` UIKit gesture recognisers intercept horizontal drags before the outer `ScrollView` can route them correctly. The `highPriorityGesture(DragGesture)` workaround added previously made things worse — it claimed *all* drag directions, freezing the outer vertical scroll entirely.

### Fix
Replaced the entire carousel stack with orthogonal `ScrollView`s — iOS routes horizontal drags to the inner one and vertical drags to the outer one automatically, with no workarounds:

```
ScrollView (vertical)       ← outer chat timeline
  └── ScrollView(.horizontal) ← new carousel, orthogonal = no conflict
       └── OutfitCardView      ← plain VStack, inner scroll removed
```

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | Replaced `TabView(.page)` + broken `highPriorityGesture` with `ScrollView(.horizontal)` + `scrollTargetBehavior(.viewAligned)` + `scrollTargetLayout()`; added custom animated dot-indicator row |
| `Features/DailyAssistant/OutfitCardView.swift` | Removed inner vertical `ScrollView` — was competing with the outer chat `ScrollView` and causing scroll freeze on tap |

---

## 2026-07-14 — UX Polish: Daily Assistant & Recommendations Navigation

**Status:** ✅ Shipped — Build Succeeded

### Problem
Buttons in the Daily Assistant and Recommendations screens felt sticky and unresponsive:
- Swiping between outfit cards in the carousel was intercepted by the outer scroll view
- Collapse/expand of historical outfit rounds had no animation (jarring instant layout jump)
- Clarification chips could be double-tapped with no visual feedback during async wait
- Item picker tiles in Try-On used `.onTapGesture` — no press-down highlight
- Button spring animation was too slow (0.35s response) making all presses feel laggy

### Changes

| File | Change |
|---|---|
| `DesignSystem/VCButtonStyles.swift` | Tightened spring `response: 0.35 → 0.22`, increased scale/opacity travel for crisper press feedback |
| `Features/DailyAssistant/DailyAssistantView.swift` | Added `.highPriorityGesture(DragGesture)` + `.clipped()` to TabView carousel; animated expand/collapse; animated try-on button label transition; added `.scrollBounceBehavior(.basedOnSize)` |
| `Features/DailyAssistant/ClarificationChipsView.swift` | Added `@State private var selectedChip` — tapping a chip immediately shows ✓ checkmark and dims all others, blocking double-taps |
| `Features/Pairing/ManualPairingView.swift` | Replaced `.onTapGesture` with `Button { }.buttonStyle(.plain)` on item cells for proper press feedback; added `.scrollBounceBehavior(.basedOnSize)` |

---

## 2026-07-14 — Premium UI pass: shared DesignSystem module + app-wide rollout

**Status:** Implemented.

The app had zero shared visual design system — no `Theme.swift`/`DesignSystem.swift`, no custom `ButtonStyle` anywhere (every button used stock `.bordered`/`.borderedProminent`), no haptics, no `.continuous` corner style, no shadows in `Features/`, and corner radii/spacing/materials applied ad hoc per-file (10/12/14/16/20pt radii used interchangeably for similar surfaces, confirmed by reading all 25 SwiftUI view files). `AccentColor.colorset` was empty, so the whole app rendered in generic system blue.

Added a new `DesignSystem/` module (sibling to `Features/`) as the single source of truth: `VCSpacing` (4/8/12/16/20/24pt grid), `VCRadius` (`swatch`=10/`control`=12/`card`=16/`prominent`=20, always `.continuous`), `VCShadow` (`subtle`/`elevated` tokens, both intentionally faint per HIG guidance), `PremiumCard` (a `.premiumCard()` view modifier — material + continuous corner + hairline stroke + optional shadow — the one mechanical target every ad hoc `.background(.material, in: RoundedRectangle(...))` call site now converts to), `VCButtonStyles` (`PrimaryButtonStyle`/`SecondaryButtonStyle`, both with press scale+spring; `SecondaryButtonStyle` takes an explicit `tint:` parameter rather than relying on environment `.tint()`, since a bare `ButtonStyle` doesn't inherit it the way `.bordered` does — this is what let `RateItemView`'s wear-again green/red semantic coding survive the migration), and `VCAccentColor` (the literal brand color for the rare call site needing a `Color` rather than the environment tint). Populated the previously-empty `AccentColor.colorset` with a new signature dynamic accent — deep oxblood `#6E2B3A` (light) / warm terracotta `#E08A6C` (dark) — built with the same `dynamic(light:dark:)` `UIColor` trait-collection pattern `ProfileChartPalette.swift` already established as this codebase's dynamic-color idiom.

Rolled the kit out across every Feature folder (Root, JobQueue, Closet, Pairing, DailyAssistant, Rating, Profile, Combinations) in one pass. Notable non-mechanical pieces: `DailyAssistantView`'s conversation UI (the newest surface, added in the prior "Conversation feature" commit) gained a small circular assistant-avatar glyph leading clarification/outfit rounds — it previously had no visual identity distinct from an anonymous material card — plus a hairline divider above the prompt bar; `TryOnResultView` went from having zero cards/materials to a proper elevated image + button treatment. Haptic feedback (`sensoryFeedback`), scoped deliberately to critical actions only (not baked into the shared button styles, which fire on every press): send/get-outfit-ideas, outfit save confirmation (both independent flows — `TryOnResultView` and `ManualPairingView`), submit rating, and delete item.

Explicitly preserved, not touched: `ProfileView`'s `List`/`Section`-based narrative content model (the deliberate 2026-07-13 redesign decision — only its buttons/chrome were restyled), every `Color(hex: item.colorProfile.primaryHex) ?? .gray` garment-swatch fallback (real data, not brand-color debt), ghost-element white overlays, the JobQueue notification badge's `.red` fill, and `ProfileChartPalette`'s validated categorical dataviz palette. `ManualPairingView`'s `PairingItemCell` had its image-clip radius and selection-ring stroke radius migrated to the same token together (a mismatch here would have visibly misaligned the ring against the photo's rounded corner). Also fixed the app's two raw hardcoded pixel-size fonts (`JobQueueBadgeButton`'s badge count, `ManualPairingView`/`ProfileView`'s large placeholder icons) to Dynamic-Type-compliant semantic text styles as a side effect of the corner-radius/typography sweep.

`xcodebuild clean build` passes. See `docs/decisions/` — no new ADR was needed since this is a presentation-layer-only change with no domain/data model impact.

## 2026-07-14 — Fixed outerwear/suit missing from generated try-on renders

**Status:** Fixed.

User reported that when a recommendation includes an outerwear item (e.g. a suit jacket/blazer — per `Domain/StylistBrain.swift`, a suit is modeled as an `outerwear`-slot item worn over a separately-filled `top`, not its own slot), the generated try-on image showed top/bottom/other slots correctly but never rendered the outerwear layer.

Root cause: `OutfitCombination.items` correctly attaches every populated slot's garment image to the `OpenRouterTryOnRenderService` request, but the accompanying instruction text (`ModelConfig.Prompts.tryOnChatInstructions`) only told the image model to place a "top" on the upper body and a "bottom" on the lower body — outerwear (and footwear/headwear/accessory/bag) were never mentioned. Since outerwear and top both target the same upper-body region, the model treated the outerwear reference image as a redundant alternative to the top and dropped it, while slots targeting other regions rendered fine.

Fix: rewrote `tryOnChatInstructions` (`Config/ModelConfig.swift`) to explicitly instruct layering — outerwear goes *over* the top, both must remain visible — and to cover footwear/headwear/accessory/bag placement instead of only top/bottom. Also rewrote `tryOnImagesPrompt` (the dedicated-Images-API branch, used if `ModelConfig.imageToImage` is ever pointed at a non-Gemini model like Seedream) — it was previously an isolated flat-lay *product-photo* prompt ("no human body parts"), not a try-on prompt at all; not the cause of this bug since that branch is currently inactive (`imageToImage` is a Gemini chat-completion model), but confirmed broken and fixed in the same pass so switching models later doesn't silently reintroduce a missing-outerwear (or missing-everything) bug. Prompt-only change, one file (`Config/ModelConfig.swift`); `xcodebuild clean build` passes.

## 2026-07-14 — Phase 1: restructured the StylistBrain recommendation prompt + fixed the interview/bag formality bug

**Status:** Fixed (Phase 1 of 2 — see `docs/decisions/stylist-intelligence-engine.md`'s 2026-07-14 addendum for the full writeup; Phase 2, multi-accessory support, is planned separately, not implemented).

Two problems: (1) an "interview" recommendation surfaced a bag — a formality mismatch nobody would actually wear — and (2) an independent review of the ~230-line `Domain/StylistBrain.swift` prompt found it mixed policy with data, read as a step-by-step chain-of-thought script, and gave the `confidence` field (already in the wire schema, never explained) no real guidance.

Root cause of (1) turned out to be **two separate biases stacking**: the prompt's only accent-slot heuristic was a coarse "errands/travel/work suggests bag," with nothing re-checking that the specific bag chosen actually cleared the scenario's formality bar; and — caught mid-implementation via user's own diagnosis — `outfitRecommendationJSONSchema` uses `strict: true`, which forces every property (including the four semantically-optional accent/layer slots) into the JSON Schema's `required` array, since strict mode has no concept of "required key, optional value." That structural fact biases a smaller model toward filling every accent slot with a plausible item just because its key exists, regardless of what the prompt prose says.

Fix, two layers:
- **Prompt (`Domain/StylistBrain.swift`):** full restructure into ROLE / MISSION / NON-NEGOTIABLE RULES / DECISION HIERARCHY / USER PROFILE / OUTPUT FORMAT. `DecisionHierarchy` compressed from 7 tiers to 6 (Color Harmony + Fit/Silhouette merged into one `.visualCohesion` tier — both were already `.penalize`-enforced with no behavioral distinction), each tier now in a Purpose/Priority/Never form instead of a paragraph. The old 6-step "Reasoning Workflow" chain-of-thought is gone, replaced by one declarative sentence. Dress Code (tier 2) now explicitly gates accent slots with scenario-specific guidance (business/interview/formal → at most one subtle accessory, never headwear, bag only if a structured/formal option exists; outdoor/casual → headwear; errands/commute/travel → bag) and an explicit instruction that a present-but-nullable key is not a request to fill it. Preferences (tier 4) split into intrinsic profile vs. learned behavior, with "ratings only break ties" made explicit. Added diversity (outfits must meaningfully differ) and ranking (sort strongest→weakest) objectives. `rationale.confidence` given a real 0-100 calibration rule.
- **Schema (`Services/OutfitRecommendationService.swift`):** `itemIDSchemaProperties` → `schemaProperty(for:)` now gives each optional slot's JSON Schema entry an explicit `description` that separates "the key must exist" from "the value should usually be null," with `bag_id`'s calling out interview/formal-business by name — a schema-level backstop for the prompt-prose fix, since prompt guidance alone isn't reliably sufficient against strict mode's required-key bias. Also added `"minimum": 0, "maximum": 100` to the previously-unbounded `confidence` integer property.

Also fixed a pre-existing, unrelated compile error blocking the whole test target (`OutfitRecommendationEngineTests.swift` used `Date()` without `import Foundation`) so verification could actually run. Updated `Vision_clotherTests/StylistBrainTests.swift` for the renamed tiers/sections and added two new cross-projection assertions (diversity objective, confidence guidance present in the prompt). Updated `docs/decisions/stylist-intelligence-engine.md` and `docs/domain/vision-clother-concepts.md` to match the 6-tier structure.

`xcodebuild clean build` passes; `StylistBrainTests` (12/12), `OutfitRecommendationServiceTests` (4/4), and `OutfitRecommendationResponseDecodingTests` (5/5) all pass. Two pre-existing, unrelated failures were observed in `OutfitRecommendationEngineTests` (a timing-budget flake and a scoring-logic assertion) in code this change never touches (`OutfitRecommendationEngine.swift`/`PairCompatibilityScoring.swift` have zero diff from `HEAD` this session) — not fixed, out of scope, flagged for a future session.

Not implemented this pass: multiple simultaneous accessories per outfit (necklace + belt + watch) — `itemsBySlot`/`itemIDsBySlot` are `[Slot: SingleValue]` everywhere in this codebase (wire model, domain model, validator, deterministic engine, the SwiftData-persisted `SavedCombination`, and the UI), so this needs a schema/engine/validator/SwiftData-migration change across ~12 files. Scoped as Phase 2, planned separately.

## 2026-07-14 — Fixed necklace/headwear/bag uploads all landing in "outerwear"; missing accent slots in recommendations was a downstream symptom, not a separate bug

**Status:** Fixed.

User reported two symptoms: (1) uploading a necklace, headwear, or bag always saved it with slot `outerwear` instead of its correct category, and (2) outfit recommendations never included headwear/accessory/bag items. Root cause was prompt/enum drift left over from the previous entry below (2026-07-14, "Closet category expansion"): `Slot` gained `headwear`/`accessory`/`bag` cases and every downstream consumer (JSON schema, `OutfitCombination`, `OutfitRecommendationEngine`, `OutfitRecommendationValidator`, `GhostElementProvider`, `StylistBrain`'s recommendation prompt) was updated to handle all seven slots — but the vision-tagging system prompt (`ModelConfig.Prompts.visionMetadataSystemPrompt`, sent to the `imageToText` model on every upload) was never updated to match. It still told the model to "classify which of these four categories" and only defined top/bottom/footwear/outerwear, so the model — with no defined bucket for a necklace/hat/bag — fell back to `outerwear` as the closest-sounding catch-all ("worn as an extra layer").

Symptom (2) was a direct consequence, not an independent defect: since every accessory-type item the user owned got saved as `outerwear`, the wardrobe had zero real items with `slot == .headwear/.accessory/.bag`, so there was nothing in those slots for the catalog builder or recommender to ever surface — `GhostElementProvider` deliberately never backfills these three slots (no universally-neutral placeholder exists for them, per the entry below). No recommendation-path code was broken or changed.

Fix: added definitions for `headwear`, `accessory`, and `bag` to `visionMetadataSystemPrompt` (`Config/ModelConfig.swift`), matching the vocabulary already used in `StylistBrain.swift`'s recommendation-side prompt, and updated "four categories" → "seven categories". Single-string change, one file. Existing mis-tagged items are fixed manually via the pre-existing `ItemDetailView` → Edit → `GarmentAttributesFormView` category picker (confirmed already functional) — no bulk re-classification tool was built, per explicit user scoping decision. `xcodebuild clean build` passes.

## 2026-07-14 — Closet category expansion: headwear, accessory, and bag slots

**Status:** Implemented.

Extended `Slot` (`Models/WardrobeItem.swift`) from four cases to seven — `headwear`, `accessory` (a single signature piece: belt/scarf/tie/watch/sunglasses, not several at once), `bag` — so the app reasons about a full "top to bottom" outfit, not just top/bottom/footwear/outerwear. Multi-garment photo splitting (tagging several items from one upload) was explicitly scoped out — `Services/BackgroundIsolationService.swift` already documents single-garment-per-photo as a deliberate guardrail this change doesn't touch.

New slots are optional accents, same treatment `outerwear` already had: `Slot.isRequired`/`Slot.hasGhostDefault` (new computed properties) replace what used to be ad hoc `case .outerwear:` special-casing across `GhostElementProvider`, the recommendation engine/validator, and the wire schema builder — a future category now needs a new `Slot` case plus these two properties, not a multi-file field hunt. `GhostElementProvider` gives the three new slots no ghost default (no completeness gap to backfill, no universally-neutral placeholder exists for them); `ClosetView` shows a real "add your first..." empty state for them instead.

`OutfitCombination`, `RecommendedOutfitWire` (`Models/OutfitRecommendationResponse.swift`), and `SavedCombination` were refactored from named top/bottom/footwear/outerwear fields to slot-keyed dictionaries (`[Slot: WardrobeItem]` / `[Slot: String]` / `[Slot: UUID]`). `RecommendedOutfitWire` still presents a fixed `{slot}_id` property per slot on the wire (OpenRouter's strict JSON schema mode needs an enumerable property list) via a custom `Codable` implementation keyed by `Slot.wireKey`; the schema builder in `Services/OutfitRecommendationService.swift` now loops over `Slot.allCases` instead of hand-listing four properties. `SavedCombination` is SwiftData-persisted, so this required this app's first `SchemaMigrationPlan`/`VersionedSchema` (`Models/SchemaMigrations.swift`, `SchemaV1` snapshotting the old shape, a `.custom` migration stage backfilling `itemIDsBySlot`/`labelsBySlot` from the dropped named columns) — landed and tested in isolation (`SavedCombinationMigrationTests`) before any other call site changed, per explicit user request given the data-loss risk of a first-ever migration.

New `StyleConstraints.desiredAccentSlots: Set<Slot>` (self-reported by the recommendation LLM in `resolved_constraints`, same mechanism `weatherLayeringRequired` already used for outerwear) drives whether `OutfitRecommendationEngine.generateCandidates` includes an accent slot in its cross-product. Each wanted optional slot's candidate list is capped to the 3 closest-formality matches before cross-producing — uncapped, 4 optional axes explode combinatorially on a well-stocked closet (a modest closet is ~40k combinations before capping). `StylistBrain`'s prompt gained guidance on when to want each accent (formal → accessory, outdoor/sunny → headwear, errands/travel/work → bag).

Updated: `ClosetView`/`ItemDetailView`/`ProfileView`'s exhaustive `Slot` switches (compiler-guided); `OutfitCardView` (three new optional slot rows); docs (`docs/domain/vision-clother-concepts.md`'s Slots/Ghost Elements sections, `Domain/CLAUDE.md`, `PRD.md` §3.1/§3.7 annotated as superseded). `xcodebuild clean build` passes. Test suite has pre-existing failures in `OutfitRecommendationEngineTests`/`OutfitRecommendationValidatorTests`/`DailyAssistantViewModelTests` unrelated to this change (see 2026-07-13 entry below, confirmed present on unmodified `main` before this work started) — deferred per user instruction rather than blocking this change on unrelated pre-existing breakage.

## 2026-07-13 — Replaced the AI/on-device background-removal toggle with a fixed two-stage pipeline (Gemini preprocess -> on-device Vision)

**Status:** Implemented. Supersedes the "manual toggle" entry below (2026-07-13, "AI-assisted background removal... as a manual toggle").

The just-shipped manual per-upload toggle (pick AI *or* on-device removal) was reversed: the user wants a single fixed pipeline for every upload, with no user choice. New sequence in `JobQueueStore.performUpload`: stage 1 sends the raw upload to `OpenRouterBackgroundIsolationService` (Gemini via OpenRouter's chat-completions branch, already configured as `ModelConfig.imageEdit`) with the existing flatlay-styling prompt; stage 2 always runs the on-device `VisionBackgroundIsolationService` (`VNGenerateForegroundInstanceMaskRequest`) on stage 1's output to produce the final transparent-background cutout that gets tagged and saved. Neither service's request/response/prompt code changed — only the pipeline wiring. Each stage still degrades gracefully on failure (falls through to the next stage's input) rather than failing the job, matching the pre-existing philosophy.

Removed: `Job.BackgroundRemovalMode` enum and `UploadPayload.removalMode`; `AddItemView`'s segmented `Picker` + `@AppStorage` persistence + captions; `AddItemViewModel.isAIBackgroundRemovalAvailable`. Renamed: `JobQueueStore`'s `aiBackgroundRemovalService` param/property -> `imagePreprocessingService`; `ServiceFactory.makeAIBackgroundRemovalService()` -> `makeImagePreprocessingService()`. `enqueueUpload` dropped its `removalMode` parameter. All `JobQueueStore(...)` construction sites (real + previews + tests) and both test files' helpers updated to match. `xcodebuild clean build` passes; `JobQueueStoreTests` (6/6) passes.

## 2026-07-13 — Prompts made editable from `ModelConfig.swift`, alongside model selection

**Status:** Implemented.

`ModelConfig.swift` already let you swap the model behind each call shape from one file; the prompt text for each call was still scattered as inline string literals inside each service's request-building function. Added a nested `ModelConfig.Prompts` enum holding one `static let` per prompt — `intentExtractionSystemPrompt`, `visionMetadataSystemPrompt`/`visionMetadataUserText`, `userProfileDerivationSystemPrompt`/`userProfileDerivationUserText`, `tryOnChatSystemMessage`/`tryOnChatInstructions`/`tryOnImagesPrompt`, `backgroundIsolationChatSystemMessage`/`backgroundIsolationFlatlayPrompt` — and repointed `OpenRouterIntentExtractionService`, `VisionMetadataExtractionService`, `UserProfileDerivationService`, `OpenRouterTryOnRenderService`, and `OpenRouterBackgroundIsolationService` at them, deleting the now-redundant inline literals. Pure extraction, no text changed.

Deliberately out of scope: the primary LLM-as-Recommender prompt (`OutfitRecommendationService`, CLAUDE.md core invariant) is built dynamically in `Domain/StylistBrain.swift`'s `DynamicPromptComposer.composeSystemPrompt`, interleaving ~5 static instructional blocks with live user-profile/feedback-affinity data across ~140 lines — not a single self-contained string like the other five, so hoisting it would mean fragmenting it into several sub-constants re-interpolated back together. Confirmed with user to leave that one in `StylistBrain.swift` for now; still edited there. Each service's JSON-schema-fallback suffix (appended only on the non-structured-output path) also stays put — it's schema plumbing tied to that file's `Codable` type, not tunable prompt content. `xcodebuild clean build` passes.

## 2026-07-13 — Fixed AI background removal silently no-op'ing after switching `imageEdit`/`imageToImage` to a Gemini model

**Status:** Fixed.

User switched `ModelConfig.imageEdit` (and `imageToImage`) from Seedream to `google/gemini-3.1-flash-lite-image` and the AI background-removal upload stopped visibly using the AI path at all — no error, just the raw photo saved. Root cause: OpenRouter only exposes Google's Gemini image-generation models via `/chat/completions` (`modalities: ["text","image"]`), never via the dedicated `/images` endpoint that Seedream/other providers use — `OpenRouterTryOnRenderService` already knew this (`isChatModel` branch) but hardcoded the check to the single literal `"google/gemini-2.5-flash-image"`, and `OpenRouterBackgroundIsolationService` had no such branch at all, so it always POSTed a Seedream-shaped body to `/images` regardless of `model`. That request fails for a Gemini model; the failure was then silently swallowed by `JobQueueStore.performUpload`'s existing "fall back to the raw, unisolated image" catch (see 2026-07-13 entry below), so the user saw their plain upload with no error and no clue why.

Fix: added `ModelConfig.isChatCompletionImageModel(_:)` (matches any `google/gemini*` model) as the single source of truth, used by both `OpenRouterTryOnRenderService` (replacing its literal-string check) and the newly-added chat-completions branch in `OpenRouterBackgroundIsolationService` (mirrors the try-on service's request/response shape: `messages` + `modalities`, image extracted from `choices[0].message.images[].image_url.url` or `message.content`). Both services now correctly route Gemini image models to `/chat/completions` and everything else to `/images`. `xcodebuild clean build` passes.

## 2026-07-13 — AI-assisted background removal (Seedream via OpenRouter), as a manual toggle alongside on-device Vision

**Status:** Implemented.

The on-device background removal (`VisionBackgroundIsolationService`, Apple Vision's `VNGenerateForegroundInstanceMaskRequest`) regularly fails on two cases: it can't tell it should drop a person wearing the garment out of frame, and it can't separate the item from a visually similar background. Added `OpenRouterBackgroundIsolationService` (`Services/BackgroundIsolationService.swift`) as a second implementation of the same `BackgroundIsolationService` protocol — sends the raw upload to `bytedance-seed/seedream-4.5` via OpenRouter's Images API (`POST /api/v1/images`) with a fixed flatlay-styling prompt, requesting `aspect_ratio: "1:1"` and `resolution: "4K"`; new `ModelConfig.imageEdit` constant keeps this independently tunable from `imageToImage` (the try-on model). Costs money, needs network, and takes several seconds (150s timeout) versus the on-device path's instant/free/offline behavior, so — per explicit user choice — this is a **manual per-upload toggle**, not an automatic replacement: `AddItemView` gained a segmented `Picker` (persisted via `@AppStorage`, defaulting to on-device, disabled when no OpenRouter key is configured via `AddItemViewModel.isAIBackgroundRemovalAvailable`). `Job.swift` gained `BackgroundRemovalMode` (`.onDevice`/`.aiRemoval`) threaded through `UploadPayload`; `JobQueueStore` now holds both isolation services and picks one per job in `performUpload`, with a mode-specific progress label ("Removing background (AI)…" vs "Isolating garment…"). Existing failure handling (fall back to the raw, unisolated image rather than failing the job) is unchanged and applies to both paths. `xcodebuild clean build` passes; `JobQueueStoreTests` (the suite covering this code) passes in full — 3 pre-existing failures in `OutfitRecommendationEngineTests`/`OutfitRecommendationValidatorTests`/`DailyAssistantViewModelTests` were confirmed present on unmodified `main` too (unrelated to this change, in recommendation-scoring code this feature doesn't touch).

## 2026-07-13 — Profile tab: replaced remaining raw charts with plain-language narrative

**Status:** Implemented.

User feedback on the just-shipped Profile redesign (below): "Your Taste, In Words" read fine, but the other four sections still didn't make sense as raw stats. Concretely: "Formality Comfort Zone" showed a closet-inventory donut (e.g. "Formal: 5") sitting directly above an unrelated rating-preference sentence, reading as two conflated numbers; "Best Pairings" labeled rows by pattern combo only (e.g. "Solid + Solid"), so 4-5 *different* item pairs all rendered as identical-looking rows each pegged at a misleadingly confident "100% (1)"; "Style Activity" was an unlabeled GitHub-style grid with no weekday/date context, so the pattern of filled cells was illegible; "Colors You Wear Well" showed a bare, context-free percentage ("Neutral 69%").

`Features/Profile/ProfileView.swift` — all four rewritten as narrative, matching "Your Taste, In Words"'s style, no math changes:
- **Formality Comfort Zone**: one sentence merges the inventory mix and the rating preference (e.g. "Your closet leans smart-casual — 5 of 9 pieces. That matches what you rate highest, too." or a callout when they diverge), below a compact proportional bar + legend (replaces the `SectorMark` donut).
- **Best Pairings**: rows now read `itemA.displayLabel + itemB.displayLabel` (e.g. "Striped Vibrant Top + Solid Neutral Bottom") instead of a pattern-only label, so distinct pairs are visibly distinct; the percentage is replaced by a qualitative sentence gated on sample count (`pairingNarrative(score:count:)`) so a single try doesn't read as equivalent confidence to a repeated one.
- **Style Activity**: replaced the 35-day grid with 2-3 sentences — total rated, most active weekday, days since last rating.
- **Colors You Wear Well**: replaced the `BarMark` + bare percentage with a ranked list using qualitative tiers ("Strongly preferred" / "Preferred" / "Occasional" / "Rarely worn") via `affinityQualifier(_:)`.

`import Charts` and the `SectorMark`/`BarMark` usages are gone from `ProfileView.swift` entirely — the only remaining chart-adjacent visuals are two `Capsule` proportion/confidence bars. `Features/Profile/ProfileChartPalette.swift` dropped its now-unused `meterTrack`/`secondaryInk` roles, keeping `categorical` (formality bar/legend) and `barFill` (pairings bar).

## 2026-07-13 — Analytics tab redesigned into a Profile tab (photo upload + intuitive taste synthesis)

**Status:** Implemented.

The Analytics tab (`AnalyticsView`, Tab 3) is now `Features/Profile/ProfileView.swift` — a real user-profile screen led by the user's own photo, not a stats dashboard. Portrait capture (camera + `PhotosPicker`) moved here from `Features/Pairing/ManualPairingView.swift`'s `portraitSection`, which previously bundled it with garment-pairing/try-on rendering; a new `ProfileViewModel` (this screen's first ViewModel — the old `AnalyticsView` never called a Service, only `@Query`/`WardrobeRepository`) owns validate → save → derive orchestration, reusing `Services/UserPortraitStorage.swift` and `Services/UserProfileDerivationService.swift` exactly as before, now with photo validation (`PersonPhotoValidationService`) run at upload time (previously only checked deep in `ManualPairingViewModel.runPipeline` at generate time — that check stays too, as cheap defense-in-depth) and derivation failures surfaced/retryable instead of silently swallowed. `ManualPairingView`'s "Try On" flow (still reached from the Closet tab's toolbar button, unchanged) now gates on `hasPortrait` and prompts the user to add a photo on Profile instead of capturing one inline.

New `Domain/TasteSynthesis.swift` adds a "Your Taste, In Words" section that translates the existing `AttributePreferenceProfile` affinity maps into ranked, thresholded plain-language statements (e.g. "You gravitate toward earth tones for tops") — explicitly a presentation-layer addition, not a new preference model: pure ranking/filtering over the same deterministic, Bayesian-shrunk affinities the recommendation engine already uses, no ML. It's also the first UI consumer of `styleTagAffinity`/`silhouetteAffinity`/`fabricWeightAffinity`, which were previously computed only for recommendation scoring. The four existing Swift Charts sections (color affinity bars, top-pairs meter, formality donut, activity grid) were kept and reframed with clearer section titles ("Colors You Wear Well," "Formality Comfort Zone," "Best Pairings," "Style Activity") rather than replaced — `AnalyticsChartPalette.swift` renamed to `ProfileChartPalette.swift` alongside the folder rename (`Features/Analytics/` → `Features/Profile/`). Tab bar entry renamed "Analytics" → "Profile" (`person.crop.circle` icon) in `RootTabView.swift`.

## 2026-07-13 — Diagnostic logging for reported "wrong image sent to LLM" ingestion bug

**Status:** Instrumented, root cause not yet confirmed.

User reported that uploading an item sometimes produces tagging output (including the free-text `description`) that's an exact match for a different, pre-existing wardrobe item — implying the wrong photo reached the vision LLM. Traced the full ingestion pipeline (`AddItemView` capture/picker → `JobQueueStore.performUpload` → `BackgroundIsolationService` → `VisionMetadataExtractionService` → `ImageStorage`) end-to-end; found no app-code bug — every stage threads image bytes and job identity together correctly via value types and UUID keys, even under concurrency (confirmed `Job`/`UploadPayload`/`Job.Kind` are plain structs, no shared/static mutable state anywhere in the codebase). User confirmed the crossing correlates with uploading items back-to-back before earlier ones finish processing, which points at either `PhotosPickerItem.loadTransferable` (Apple framework, multi-select) or a still-unproven runtime race. Added content-fingerprint (`SHA256` prefix) diagnostic logging via `PerfLog.logger` at every ingestion checkpoint — raw capture (camera + picker, including `pickerItem.itemIdentifier`), post-background-isolation/sent-to-LLM, tagged description, and saved item/filename — so the next occurrence's device console log will show exactly which stage the image bytes actually diverge at. No behavior change; `xcodebuild` clean build passes. Next step once logs capture a repro: pinpoint the exact stage and apply a targeted fix (or serialize upload jobs if it's confirmed to be concurrency-related).

## 2026-07-13 — Style Analytics charts (Color Affinity Breakdown, Top Pairs meter, Formality donut, Look History activity grid)

**Status:** Implemented.

`AnalyticsView` (Tab 3) upgraded from plain text rows to real charts — first adoption of Swift Charts (`import Charts`) in this codebase. New "Color Affinity Breakdown" section adds a Tops/Bottoms/Shoes segmented picker over a ranked `BarMark` chart; this required a genuine domain-layer addition, not just UI: `Domain/AttributePreferenceProfile.swift`'s `colorVibeAffinity` was previously a single flat map with no `Slot` dimension, so `RatedAttributes`/`OutfitDimensionRatedAttributes` gained an optional `slot: Slot?` field and `AttributePreferenceProfile` gained a parallel `colorVibeAffinityBySlot: [Slot: [ColorVibe: Double]]`, populated from `item.slot` in `Data/WardrobeRepository.swift`'s `fetchFeedbackHistory()`. "Top Pairs" rows now show a mini stacked-bar meter (score vs. remainder) instead of bare percentage text — note the underlying data already had explicit dislike tracking (`OutfitFeedback`/`ItemFeedback`/`PairFeedback` `liked*` fields) before this change; a 100% pair score is a small-sample-size artifact, not a missing feature. "Closet Formality Balance" is now a `SectorMark` donut with a legend. "Look History" is now a GitHub-style activity grid (`LazyVGrid` of day cells, opacity-scaled by that day's rated-outfit count) — this supersedes an earlier code comment that had deferred a calendar view to "a later iteration." New `Features/Analytics/AnalyticsChartPalette.swift` centralizes theme-aware chart colors (validated categorical/sequential palette, fixed hue order, light/dark variants) shared across all four visuals. See `docs/domain/vision-clother-concepts.md` for the `colorVibeAffinityBySlot` field.

## 2026-07-12 — Fixed: unrated items showed "Not yet rated" and were skipped by the LLM recommender

**Status:** Fixed.

`Domain/ItemRatingScoring.swift`'s `score(for:history:)` returned `nil` for an item with no feedback, on the theory that `itemPreference`'s neutral 0.5 prior was a scoring convenience rather than a real rating — both `ClosetView`/`ItemDetailView` then rendered "Not yet rated" for that `nil`. In practice this meant every freshly uploaded item (before any feedback exists) showed no rating, and — once wired into `Domain/WardrobeCatalogBuilder.swift`'s LLM-facing catalog as `"user_rating": null` — the LLM recommender was observed avoiding those items entirely rather than treating them as neutral, despite the prompt instructing it to. Changed `score` to return the natural `Int` (50 for zero feedback, matching `itemPreference`'s existing neutral-prior behavior everywhere else in the app) instead of special-casing `nil`; removed the now-dead "Not yet rated" UI branches in `ItemDetailView`/`ClosetView`; updated `StylistBrain`'s tier-4 prompt wording to describe 50 as the neutral default rather than referencing a "null/unrated" state that no longer occurs. See `docs/domain/vision-clother-concepts.md`'s "Item Rating Score (Closet UI)" section.

## 2026-07-12 — Per-item rating score in the Closet

**Status:** Implemented.

Each closet item now shows a dynamic 0-100 rating badge (`ClosetView`'s grid cell + `ItemDetailView`'s metadata row), aggregated from every feedback source that references the item: direct `ItemRating`s, outfit favorite/weakest picks, and `PairFeedback` ("liked together" from Manual Pairing). New `Domain/ItemRatingScoring.swift` reuses the existing `PairCompatibilityScoring.itemPreference` Bayesian-shrinkage math (no new formula) over `FeedbackHistory.itemFeedback` + `pairFeedback`. Computed fresh on each view appearance — no persisted field on `WardrobeItem`, no migration. Items with no feedback show "Not yet rated" rather than a literal 50%. See `docs/domain/vision-clother-concepts.md`'s "Item Rating Score (Closet UI)" section for the full contract.

## 2026-07-11 — Automatic saving of generated try-on images

Generated outfit/try-on images are now durably persisted automatically rather than being an ephemeral render result.

## 2026-07-10 — Outfit-recommendation bug fixes: score >100% and inconsistent card count

Fixed the Pair-Compatibility scoring bug that could push a score above 100%, and fixed inconsistent outfit-card counts on the Daily Assistant recommendation results.

## 2026-07-10 — Fixed: images and combinations invisible

Investigated and fixed a rendering bug where wardrobe item images and saved combinations weren't appearing — item IDs already flowed correctly end-to-end; the bug was in how `OutfitCardView` rendered items.

## 2026-07-10 — LLM-as-Recommender reversal + Stylist Intelligence Engine

The LLM became the primary outfit recommender (previously only an intent/constraint extractor) — see `docs/decisions/resolved-v1.md` and `docs/decisions/stylist-intelligence-engine.md` for full rationale. `Domain/OutfitRecommendationValidator.swift` added as the deterministic trust boundary/fallback gate. Decision Hierarchy tiers, resolved-constraints self-report, symmetric taste injection, and dimension-based outfit feedback (`RateCombinationView`, `AttributePreferenceProfile`) landed in this window.

## 2026-07-10 — Initial commit

Clean repo structure for Vision Clother — SwiftUI iOS client, deterministic scoring engine, SwiftData persistence.
