# Vision Clother — Change Timeline

---

## 2026-07-16 — Feature: Firestore + Cloud Storage Wardrobe Sync (Delta + Durable Outbox)

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Signing in with a different Google/phone account showed the exact same local closet every time. `AuthService`/`isSignedIn` only ever gated which network services `ServiceFactory` picked (real vs. mock) — it was never consulted by `WardrobeRepository`, which lived in one shared, ownerless local `ModelContainer`. The user asked for the full fix (real per-account cloud sync), and — once told this targets a real App Store release at production scale, not a personal single-device app — specifically asked for delta sync (not full snapshot push/pull), a durable local outbox/dirty-bit (not fire-and-forget writes), real per-record conflict resolution, and compressed/lazy photo transfer, rather than the cheaper personal-app shortcuts an initial pass had proposed.

### Changes
Firestore is the source of truth once an account has synced; local SwiftData stays a full on-device cache/mirror, wiped-and-reloaded on account switch (no per-record `ownerUID`). Every synced doc carries a Firestore-authoritative `updatedAt` (`FieldValue.serverTimestamp()`, merged in server-side, never trusted from a client field); steady-state pulls query only `updatedAt > lastPulledAt`; deletes are soft (`isDeleted` tombstones, since a hard delete is invisible to a `>` query). One new local-only table, `SyncMetadata` (`SchemaV9` — the only schema change), holds a JSON-encoded DTO snapshot per dirty entity; `SyncingWardrobeRepository` (decorates `WardrobeRepository`, same idiom as `CachedTryOnRenderService`) upserts a dirty row in the same local save as every mutation, and `SyncOutboxWorker` drains dirty rows with exponential backoff on every mutation and every foreground. Conflict resolution is per-record last-write-wins with the dirty side protected — a pull never overwrites a local row that's dirty and at least as new. First sign-in for an account pushes this device's existing local data up if the account has no cloud history yet (protects pre-auth data), or wipes-and-fully-pulls if it does (a second device/reinstall); every later reconcile is delta-only. Sign-out does not wipe local data (matches the existing "sign-in is optional" posture) — the wipe happens lazily on the next *different* account's sign-in. 9 of 11 `@Model` types sync (`WardrobeItemEmbedding`/`RecommendationImpressionEvent` stay local-only). Photos upload to Cloud Storage at upload time only — PNG (alpha-preserving, wardrobe cutouts) or JPEG (opaque, saved-combination renders) — downscaled to 1024px; pull applies metadata immediately and downloads missing photo bytes in an unawaited background pass. No backend involvement — the client talks to Firestore/Storage directly, gated by security rules keyed on `request.auth.uid`.

| File | Change |
|---|---|
| `Vision_clother/Models/SyncMetadata.swift` (new) | Local-only outbox/conflict-resolution table (`SchemaV9`) |
| `Vision_clother/Models/SchemaMigrations.swift` | `SchemaV9` added (lightweight migration, new independent table) |
| `Vision_clother/Data/Sync/FirestoreDTOs.swift` (new) | One `Codable` DTO per synced type, framework-agnostic (no `updatedAt`/`isDeleted` fields — those are sync metadata, handled at the Firestore call site) |
| `Vision_clother/Services/WardrobeSyncService.swift` (new) | Protocol + `FirestoreWardrobeSyncService`/`MockWardrobeSyncService` — push (server-timestamp merge), delta/full pull, sync status, image upload/download |
| `Vision_clother/Data/SyncingWardrobeRepository.swift` (new) | Decorates `WardrobeRepository`, marks `SyncMetadata` dirty + best-effort image upload on every mutation |
| `Vision_clother/Data/SyncOutboxWorker.swift` (new) | Drains dirty `SyncMetadata` rows with exponential backoff |
| `Vision_clother/Data/WardrobeSyncCoordinator.swift` (new) | Bootstrap (push-local-up / wipe-and-pull) + delta reconcile + account-switch wipe, driven by `AuthService.shared.$uid` |
| `Vision_clother/Data/ImageStorage.swift` | Added `write(_:filename:)`, `wipeAll()`, `downscaledPNGForUpload`, `downscaledJPEGForUpload` |
| `Vision_clother/Services/AuthService.swift` | Added `@Published uid: String?` |
| `Vision_clother/Vision_clother/Services/ServiceFactory.swift` | Added `makeWardrobeSyncService()` |
| `Vision_clother/Vision_clotherApp.swift` | Constructs `WardrobeSyncCoordinator`; `scenePhase` foreground hook calls `reconcileIfSignedIn()`; repository construction renamed to `SyncingWardrobeRepository` |
| 18 call sites across `Features/` | Mechanical rename `SwiftDataWardrobeRepository(modelContext:)` → `SyncingWardrobeRepository(modelContext:)` |
| `Vision_clother.xcodeproj/project.pbxproj` | `FirebaseStorage` SPM product linked (via the `xcodeproj` Ruby gem, same approach as prior Firebase package additions) |
| `backend/storage.rules` (new), `backend/firestore.rules`, `backend/firebase.json`, `backend/firestore.indexes.json` (new) | Per-uid Storage rules; Firestore rules opened from deny-all to `users/{uid}/**` scoped to `request.auth.uid` (`rateLimits` stays admin-only); both deployed live |
| `docs/decisions/resolved-v1.md`, `CLAUDE.md`, `Vision_clother/Data/CLAUDE.md`, `docs/ios/architecture.md` | Cloud Sync decision section; Core Invariant reworded (photos now leave the device via Cloud Storage; the recommendation LLM call itself still never sees images) |

## 2026-07-16 — Fix: Cap Concurrent In-Flight Jobs in `JobQueueStore`

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
A security review flagged that `enqueueUpload`/`enqueueTryOn` each spawned an independent, uncapped background `Task` hitting the OpenRouter-backed API directly, with no maximum in-flight job count. Combined with the embedded API key, a bulk action (e.g. importing 50 photos) or deliberate abuse could fire dozens of concurrent requests against a paid third-party API with no circuit breaker.

### Changes
Added a `maxConcurrentJobs = 3` cap enforced via a `pendingStarts` FIFO queue: `scheduleStart(_:_:)` starts a job immediately if under the cap, otherwise queues its start closure (job stays `.queued`, already the existing status for this case). `startNextPendingIfAny()` drains the queue by one whenever a running job frees a slot — wired into `finishJob` (covers all upload terminal paths and explicit cancellation) and both terminal cases of `handleTryOnUpdate` (try-on succeeded/failed). `cancelJob` also removes a still-queued (not yet started) job from `pendingStarts` so cancelling before a slot opens doesn't later start it anyway.

| File | Change |
|---|---|
| `Vision_clother/Vision_clother/Features/JobQueue/JobQueueStore.swift` | Added `maxConcurrentJobs`/`pendingStarts`/`scheduleStart`/`startNextPendingIfAny`; `enqueueUpload`, `retryUpload`, `enqueueTryOn` now go through `scheduleStart` instead of starting their `Task` unconditionally; `finishJob` and `handleTryOnUpdate`'s terminal cases drain the pending queue; `cancelJob` also prunes `pendingStarts` |

## 2026-07-16 — Refactor: Deduplicate Two-Stage Isolate Fallback in `JobQueueStore`

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
A code-review pass flagged that `JobQueueStore.performUpload` (the tracked-upload path) and `JobQueueStore.isolateAndTag` (the prospective-purchase path) duplicated the same two-stage isolate sequence — Gemini preprocess falling back to the raw photo, then on-device Vision falling back to stage 1's output — almost verbatim, with a code comment explicitly acknowledging the duplication as a deliberate lower-risk tradeoff over restructuring.

### Changes
Extracted the fallback sequencing (not the job-status/cancellation interleaving, which genuinely differs between the two call sites) into two small private helpers, `isolateStage1(_:)` and `isolateStage2(_:)`, each a one-line `try? ... ?? fallback`. `performUpload` still sets job status and checks `Task.isCancelled` between stages; `isolateAndTag` calls both helpers back-to-back with no interleaving, matching its one-shot, non-job-tracked nature.

| File | Change |
|---|---|
| `Vision_clother/Vision_clother/Features/JobQueue/JobQueueStore.swift` | Added `isolateStage1`/`isolateStage2` private helpers; `performUpload` and `isolateAndTag` both call them instead of duplicating the do/catch fallback logic |

## 2026-07-16 — Backend: Google Sign-In + Phone Auth Replace Sign in with Apple; Firestore Provisioned

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`), backend tests 12/12 passing

### Problem
The Firebase proxy shipped earlier the same day assumed Sign in with Apple + App Check (App Attest) as the only auth path — both require a paid Apple Developer account, which isn't available yet. The user asked to wire the app to their existing Firebase project (`visionclother`, number `1008598090428`), use Google Sign-In + Phone Number auth instead, register the iOS app in that project, and provision Firestore.

### Changes

| File | Change |
|---|---|
| `backend/.firebaserc` | Points at project `visionclother` (via `npx -y firebase-tools@latest use`) |
| Firebase project (via CLI, no console clicks except the one below) | iOS app registered (`apps:create IOS`), `GoogleService-Info.plist` fetched (`apps:sdkconfig IOS`), Firestore Standard-edition default database created, Google Sign-In enabled (`firebase.json`'s `auth` block + `deploy --only auth`) |
| `backend/firestore.rules`, `backend/firebase.json` | New deny-all Firestore rules (only the Admin SDK's rate-limit counter touches it) |
| `backend/functions/src/app.ts` | Middleware chain drops `verifyAppCheck` — App Check deferred, same paid-account blocker |
| `backend/functions/src/middleware/verifyAppCheck.ts` | Deleted (never actually built — the SPM product was never linked) |
| `backend/functions/test/middleware.test.ts` | App-Check test cases removed |
| `Vision_clother.xcodeproj/project.pbxproj` | `FirebaseDatabase` (Realtime Database, mistakenly linked) swapped for `FirebaseFirestore`; `GoogleSignIn-iOS` package added; `INFOPLIST_FILE` set on the app target (Debug/Release) to a supplemental `Config/URLSchemes.plist`, kept alongside `GENERATE_INFOPLIST_FILE = YES` — done via a one-off script using the same `XcodeProj` Swift library `xcode-project-setup`'s vetted script uses, not hand-edited text |
| `Vision_clother/Config/URLSchemes.plist` (new) | `CFBundleURLTypes`: Google's `REVERSED_CLIENT_ID` + the app's bundle ID (for phone auth's reCAPTCHA redirect) |
| `Vision_clother/Config/GoogleService-Info.plist` (new) | Firebase client config for the `visionclother` project — not a secret, safe to commit |
| `Vision_clother/Services/AuthService.swift` | Sign in with Apple (`AuthenticationServices`/nonce/delegate) replaced with `signInWithGoogle()` (`GoogleSignIn` SDK), `startPhoneSignIn`/`confirmPhoneSignIn` (`PhoneAuthProvider`), new `signOut()` |
| `Vision_clother/Config/FirebaseBootstrap.swift` | App Check provider registration dropped; configures `GIDSignIn` with Firebase's client ID |
| `Vision_clother/Services/ProxyAuthHeaders.swift` | Drops the `X-Firebase-AppCheck` header |
| `Vision_clother/Vision_clotherApp.swift` | `.onOpenURL` routes the Google consent redirect and phone-auth reCAPTCHA redirect back into the app |
| `Vision_clother/Vision_clother/Features/Profile/AccountSectionView.swift` (new) | Google button + phone number/OTP two-step flow + sign-out, wired as the first section in `ProfileView.swift` |
| `docs/backend/architecture.md`, `docs/backend/conventions.md`, `docs/decisions/resolved-v1.md`, `backend/README.md` | Reflect Google/Phone auth, dropped App Check, Firestore on `visionclother` |

## 2026-07-16 — Docs: Reconcile Try-On Architecture Docs with OpenRouter Reality

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
A code-review pass flagged that `docs/decisions/resolved-v1.md`, `docs/ios/architecture.md`, `docs/architecture.md`, and `docs/backend/architecture.md` all still described the try-on renderer as Fal + `fashn/tryon/v1.6` (async submit → poll queue, one garment per call). No `Fal*.swift` file has ever existed in the tree — the app moved to `Services/OpenRouterTryOnRenderService.swift` (Gemini image models via OpenRouter, single synchronous request, all garments composed in one call) before the Fal path was ever implemented, and the docs were never updated to match.

### Changes

| File | Change |
|---|---|
| `docs/decisions/resolved-v1.md` | Diffusion Provider decision marked **superseded**; new decision documents OpenRouter/Gemini (`ModelConfig.imageToImage`), single-call multi-garment compose, no async poll |
| `docs/architecture.md`, `docs/ios/architecture.md`, `docs/backend/architecture.md`, `docs/backend/conventions.md`, `docs/approach/conventions.md` | All Fal/FASHN references (diagrams, model names, "async submit → poll", per-garment chaining, API key mentions) replaced with the actual OpenRouter/Gemini single-request architecture |
| `CLAUDE.md`, `Vision_clother/Services/CLAUDE.md` | "Fal pipeline" async-boundary guardrail rewritten to describe `OpenRouterTryOnRenderService`'s single bounded-timeout request instead of a poll loop |
| `Vision_clother/Vision_clother/Features/DailyAssistant/DailyAssistantViewModel.swift` | Stray comment citing `FalTryOnRenderService`'s precedent renamed to `OpenRouterTryOnRenderService` |
| `Vision_clother/Services/APIKeys.swift` | Removed dead `APIKeys.fal` (no remaining caller) |
| `Vision_clother/Config/README.md`, `Secrets.example.plist`, `Secrets.plist` | Removed `FAL_API_KEY` — never read by any real service |

## 2026-07-15 — Feature: Multi-Accessory Outfits

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Closes deferred item #1 from `docs/decisions/stylist-intelligence-engine.md`: an outfit could only ever carry one accent item, so "bag + belt + jewelry" couldn't be recommended simultaneously.

### Root Cause
Cross-slot accessorizing (bag + headwear + accessory) already worked — `Slot` already had three independent accent cases. The real gap was the single `.accessory` slot being an explicit catch-all ("one per outfit, not several simultaneously" — `StylistBrain.swift`/`OutfitRecommendationService.swift`), so belt and jewelry collided for the one slot.

### Changes

| File | Change |
|---|---|
| `Domain/FashionKnowledgeConstants.swift` | New `maxSupplementaryAccessories = 2` |
| `Models/OutfitRecommendationResponse.swift` | `RecommendedOutfitWire.supplementaryAccessoryIDs: [String]`, decoded/encoded via the existing dynamic-key container |
| `Services/OutfitRecommendationService.swift` | JSON schema gained `supplementary_accessory_ids` (array, capped, required key/optional-empty) |
| `Domain/OutfitRecommendationValidator.swift` | New explicit resolution step alongside (not inside) the existing per-slot loop; extends the duplicate-id check; truncates over-cap rather than rejecting |
| `Models/OutfitCombination.swift` | New `supplementaryAccessories: [WardrobeItem]`, folded into `items` |
| `Domain/StylistBrain.swift` | Prompt rewritten: business/interview/formal must leave it empty; casual/going-out may use up to the cap |
| `Models/SavedCombination.swift`, `SchemaMigrations.swift`, `Vision_clotherApp.swift` | New `supplementaryAccessoryItemIDs`/`Labels`; new `SchemaV8`, additive `.lightweight` migration |
| `Features/JobQueue/JobQueueStore.swift`, `Features/Combinations/CombinationsViewModel.swift` | Both `SavedCombination` build/resolve integration points carry the new fields |
| `Features/DailyAssistant/OutfitCardView.swift`, `DailyAssistantViewModel.swift` | One card row per supplementary accessory; included in the LLM replay summary |

## 2026-07-15 — Feature: "What Would You Change?" Checklist (Level 3 Outfit Feedback)

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Closes deferred item #2 from `docs/decisions/stylist-intelligence-engine.md`: Level 1/2 dimension-based outfit feedback shipped, but the "what specifically was wrong" structured edit checklist (Level 3) was scoped and never built.

### Changes

| File | Change |
|---|---|
| `Models/FeedbackEvent.swift` | New `OutfitChangeReason` enum (7 cases); `OutfitFeedback.changeReasonsRaw: [String]` |
| `Domain/AttributePreferenceProfile.swift` | `OutfitDimensionRatedAttributes` gained `pattern`/`patternDissatisfaction`; `build(from:)` folds it into `patternAffinity` — a new outfit-level entry point for that map |
| `Data/WardrobeRepository.swift` | `OutfitRatingSubmission.changeReasons`; `fetchFeedbackHistory()` clamps the flagged dimension(s) to `min(existing, 0.1)` per rated outfit |
| `Features/Rating/RateCombinationViewModel.swift`, `RateCombinationView.swift` | New checklist section + `toggleChangeReason` (tooFormal/tooCasual mutually exclusive) |
| `Models/SchemaMigrations.swift`, `Vision_clotherApp.swift` | New `SchemaV7` — additive `[String]` column, `.lightweight` migration |

## 2026-07-15 — Feature: Impression/Selection Event Capture

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Closes deferred item #3 from `docs/decisions/stylist-intelligence-engine.md`: the app logs ML drift (`[AI-Stylist-ML]`) but never captured which of several shown candidate outfits the user actually picked/ignored — the highest-value signal for tuning the ranker.

### Changes

| File | Change |
|---|---|
| `Models/RecommendationImpressionEvent.swift` (new) | Event-sourced `@Model` — one row per candidate shown (`roundID`, `rank`, denormalized `itemIDsBySlot`, `shownAt`), `selectedAt` filled in later |
| `Data/WardrobeRepository.swift` | New `recordImpressions(roundID:outfits:)` / `recordSelection(outfitID:)`, both best-effort, logged under `[AI-Stylist-ML]` |
| `Features/DailyAssistant/DailyAssistantViewModel.swift` | `sendTurn`'s success branch calls `recordImpressions`; `startTryOn` calls `recordSelection` |
| `Models/SchemaMigrations.swift`, `Vision_clotherApp.swift` | New `SchemaV6` — purely additive new table, `.lightweight` migration |

Not wired into any ranker yet — this phase only makes the data exist, same posture as `OutfitRecommendationValidator.RejectionReason`.

## 2026-07-15 — Bug Fix: "How does it look on me?" → "Render failed: Invalid image data-url"

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Tapping "How does it look on me?" on a Daily Assistant recommendation failed with an opaque render-API error instead of rendering the try-on image.

### Root Cause
`DailyAssistantView.placeholderBaseImageData` fell back to empty `Data()` whenever the user hadn't captured a base portrait yet (`UserPortraitStorage.load() == nil`). That empty data base64-encoded to an empty `data:image/png;base64,` URL, which OpenRouter rejected with `"Invalid image data-url"`, surfaced as `TryOnError.renderFailed`. Not a regression — a known, previously-commented gap. `ManualPairingView`/`ManualPairingViewModel` already guard this exact precondition elsewhere in the app.

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | `onStartTryOn` now checks `UserPortraitStorage.exists` before enqueuing the try-on job; shows an alert ("Add a photo of yourself on your Profile tab to try on outfits.") instead of sending empty image data |

## 2026-07-15 — Feature: Item Rating question redesign + Swipe-to-Learn implicit swipe bridge

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Two related asks: (1) the per-item rating form's questions (Confidence, Versatility, Predicted Wear Frequency, Quality Perception) read as generic/out-of-scope, and (2) close the loop between the new rating flow and the Swipe-to-Learn visual taste system so ratings — not just the discovery deck — keep the k-means centroids fresh.

### Root cause (question redesign)
`Domain/AttributePreferenceProfile.swift`'s `RatedAttributes` carried one blended `value` (`ItemRating.normalizedValue`, an average across all 8 old questions) that was reused as the signal for three unrelated affinities — color, pattern, and formality — despite no dedicated color or pattern question existing anywhere. Versatility/Frequency/Quality Perception fed nothing else; they only diluted the blend.

### Changes

| File | Change |
|---|---|
| `Models/ItemRating.swift` | Replaced Confidence/Versatility/Frequency/Quality Perception with `colorLike`, `patternLike` (optional, skipped for solid-pattern items), `formalityFit`; rewrote `FitRating.normalizedRating`; clean-break schema (no shipped users) |
| `Domain/AttributePreferenceProfile.swift` | `RatedAttributes` gained dedicated `colorLike`/`patternLike`/`formalityFit`/`silhouetteFit`/`fabricComfort` fields (replacing the blended `value`); `build()`'s accumulation loop feeds each into its matching affinity map directly |
| `Domain/VisualPreferenceProfile.swift` | `VisualClusterUpdater.update` gained an optional `learningRate: Float?` (default `nil` = unchanged `1/weight` step); added `implicitLearningRate = 0.05` for rating-derived nudges |
| `Data/WardrobeRepository.swift` | `recordItemRating` signature updated; new `applyImplicitSwipe`/`loadOrCreateVisualPreferenceState` helpers fold a rating's liked/disliked signal into the same centroids `recordSwipe` maintains, using the gentle learning rate; best-effort, no `SwipeEvent` written |
| `Features/Rating/RateItemViewModel.swift`, `RateItemView.swift` | New question set: Fit, Comfort, Color, Pattern (conditional), Formality Fit, Style Identity, Wear Again |

See `docs/decisions/stylist-intelligence-engine.md` for full rationale, including why `dislikePenaltyWeight = 1.2` / `maxBonusMagnitude = 0.3` were left untouched.

## 2026-07-14 — Feature: Swipe-to-Learn Visual Taste + Embedding-Ranked Catalog Retrieval

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Two related asks: (1) let the app learn visual taste from a Tinder-style like/dislike swipe deck of stock fashion photos, and (2) `Domain/WardrobeCatalogBuilder.swift`'s slot-capping truncation (`slotBalancedSample`) dropped overflow items in arbitrary insertion order once a closet's per-slot item count exceeded its share of `maxItems` — a real user with, say, 40 tops and a 20-item budget would have half their tops silently invisible to the recommendation LLM for no principled reason.

### Fix
Both are solved by the same on-device embedding infrastructure rather than two separate systems:
1. **On-device embeddings, no bundled ML.** `Services/ImageEmbeddingService.swift`'s `VisionFeaturePrintEmbeddingService` uses Apple's free `VNGenerateImageFeaturePrintRequest` to turn any photo into an L2-normalized vector — no CoreML model to ship, no network call.
2. **Online mini-batch k-means.** `Domain/VisualPreferenceProfile.swift`'s `VisualClusterUpdater` maintains up to 3 centroids per liked/disliked side (nearest-centroid nudge, not a single running mean) so genuinely bimodal taste (e.g. "goth-grunge" + "pastel-preppy") doesn't collapse into a meaningless average. `VisualPreferenceProfile.affinityBonus` scores a candidate embedding via bounded (±0.3) cosine similarity against those centroids.
3. **A second, independent re-scoring signal — never touches the LLM.** The app's Core Invariant is that the recommendation LLM only ever sees text/hex attributes, never images. `Domain/OutfitRecommendationEngine.swift`'s `outfitScore` folds in a new `meanVisualBonus` term structurally identical to the existing `AttributePreferenceProfile.affinityBonus` re-rank step — it only runs after LLM candidates return.
4. **Embedding-ranked catalog truncation.** `WardrobeCatalogBuilder.slotBalancedSample` now ranks a slot's candidates by learned visual affinity before capping to `perSlot`, replacing the old arbitrary `.prefix(perSlot)` order. Hard filters (ghost-exclusion, season/formality) are untouched — this only reorders which already-valid items survive the cap. A cold-start (untrained) profile scores every item 0, so with Swift's stable sort this is a byte-for-byte no-op until the user actually swipes.
5. **Swipe deck UI.** `Features/SwipeDiscovery/` — a card-stack `DragGesture` view sourcing photos from a new licensed stock-photo service (`Services/StockImageFeedService.swift`, Pexels — simpler attribution-only licensing than Unsplash), entered from a new "Discover Your Style" row in `Features/Profile/ProfileView.swift`.

### Changes

| File | Change |
|---|---|
| `Models/SwipeDiscovery.swift` (new) | `SwipeEvent`, `VisualCentroid`, `VisualPreferenceState`, `WardrobeItemEmbedding` |
| `Models/SchemaMigrations.swift` | Added `SchemaV4` (purely additive, `.lightweight` V3→V4 migration) |
| `Vision_clotherApp.swift` | `Schema(SchemaV3.models)` → `Schema(SchemaV4.models)` |
| `Services/ImageEmbeddingService.swift` (new) | Protocol + `VisionFeaturePrintEmbeddingService` + `MockImageEmbeddingService` |
| `Services/StockImageFeedService.swift` (new) | Protocol + `PexelsImageFeedService` + `MockStockImageFeedService`; `APIKeys.pexels` |
| `Domain/VisualPreferenceProfile.swift` (new) | `VisualClusterUpdater` (online k-means) + `VisualPreferenceProfile` (affinity scoring) |
| `Domain/OutfitRecommendationEngine.swift` | `FeedbackHistory.visualProfile`/`.itemEmbeddings`; `outfitScore`'s `meanVisualBonus` term |
| `Domain/WardrobeCatalogBuilder.swift` | `slotBalancedSample` ranks by visual affinity before capping (`rank(_:history:)`) |
| `Data/WardrobeRepository.swift` | `recordSwipe`/`fetchVisualPreferenceState`/`updateVisualPreferenceState`/`fetchWardrobeItemEmbedding`/`saveWardrobeItemEmbedding`; `fetchFeedbackHistory()` reads visual-taste state and lazily caches per-item embeddings |
| `Features/SwipeDiscovery/` (new) | `SwipeDiscoveryViewModel` + `SwipeDiscoveryView` (card stack, drag gesture, like/dislike buttons) |
| `Features/Profile/ProfileView.swift` | New "Discover Your Style" entry point |
| `ServiceFactory.swift` | `makeImageEmbeddingService()`, `makeStockImageFeedService()` |
| `Config/` | `PEXELS_API_KEY` added to `Secrets.plist`/`Secrets.example.plist`/`README.md` |
| `Vision_clotherTests/*` | New: `VisualClusterUpdaterTests`, `VisualPreferenceProfileTests`, `ImageEmbeddingServiceTests`, `SchemaV4MigrationTests`, `SwipeDiscoveryViewModelTests`. Extended: `OutfitRecommendationEngineTests`, `WardrobeCatalogBuilderTests`, `WardrobeRepositoryTests`. Updated 6 `WardrobeRepository` test doubles with the 5 new protocol methods. |

---

## 2026-07-14 — Optimization: Database Query Pruning & Background Preference Rebuilding (Bottleneck C)

**Status:** ✅ Shipped — Build Succeeded

### Problem
In `fetchFeedbackHistory()`, the app fetched all database rows for feedback and ratings and processed them sequentially in memory on `@MainActor`. Recomputing the entire historical feedback history on every view appearance causes linear degradation of responsiveness as history grows, freezing the UI.

### Fix
1. **Time-window predicates:** Added a 180-day time-window predicate to SwiftData queries for `PairFeedback`, `ItemFeedback`, `ItemRating`, and `OutfitFeedback` inside `fetchFeedbackHistory()`, resolving the query bloat at the database level.
2. **Background processing:** Overloaded `AttributePreferenceProfile.build()` with a `[ItemAttributeSnapshot]` payload and offloaded the computation to `Task.detached` to avoid blocking `@MainActor`.
3. **Async Signatures:** Made `fetchFeedbackHistory()` async and updated all 4 call sites (`ClosetView`, `ItemDetailView`, `ProfileViewModel`, `DailyAssistantViewModel`) to run the fetch concurrently.

### Changes

| File | Change |
|---|---|
| `Domain/AttributePreferenceProfile.swift` | Added `ItemAttributeSnapshot` sendable struct; added overload for `build(from:outfitDimensionRatings:inventorySnapshots:now:)` |
| `Data/WardrobeRepository.swift` | Updated `fetchFeedbackHistory()` to be async; added 180-day query predicate pruning; offloaded profile rebuilding using `Task.detached` |
| `Features/Closet/ClosetView.swift` | Made `loadFeedbackHistory()` fetch asynchronously inside a `Task` block |
| `Features/Closet/ItemDetailView.swift` | Made `loadFeedbackHistory()` fetch asynchronously inside a `Task` block |
| `Features/Profile/ProfileViewModel.swift` | Updated `refreshFeedbackHistory()` to fetch asynchronously in a `Task` block |
| `Features/DailyAssistant/DailyAssistantViewModel.swift` | Updated `resolveOutfits()` to call `fetchFeedbackHistory()` asynchronously with `await` |
| `Vision_clotherTests/*` | Updated test mock stubs in 7 test suites to conform to the updated async protocol signature |

---

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
| `Features/DailyAssistant/DailyAssistantView.swift` | Added `.highPriorityGesture(DragGesture)` + `.clipped()` to TabView carousel to claim horizontal swipes from the outer ScrollView; animated expand/collapse with `.spring`; animated try-on button label transition; added `.scrollBounceBehavior(.basedOnSize)` |
| `Features/DailyAssistant/ClarificationChipsView.swift` | Added `@State private var selectedChip` — tapping a chip immediately shows ✓ checkmark and dims all others, blocking double-taps before async round completes |
| `Features/Pairing/ManualPairingView.swift` | Replaced `.onTapGesture` with `Button { }.buttonStyle(.plain)` on item cells for proper press feedback; added `.scrollBounceBehavior(.basedOnSize)` to horizontal item picker |
