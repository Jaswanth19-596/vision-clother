# iOS Client Architecture

SwiftUI app, iOS 26+ deployment target, Swift 5.0 language mode, no third-party dependencies (no SPM packages) — every network call is raw `URLSession` (see § Networking below for why).

Project location: `Vision_clother/Vision_clother.xcodeproj`, scheme `Vision_clother`. Uses Xcode's file-system-synchronized groups, so any file dropped into the source tree under `Vision_clother/Vision_clother/` is picked up automatically — no `.pbxproj` editing needed for new source files.

## Layering

```
Features/   SwiftUI views + @Observable view models — one folder per tab/screen
   ↓ calls
Domain/     Pure, synchronous, unit-tested business logic — no I/O, no SwiftData
   ↑ reads
Data/       WardrobeRepository protocol + SwiftDataWardrobeRepository — the only
            place that touches a ModelContext
Services/   Network-facing protocols (IntentExtractionService, TryOnRenderService)
            + real (OpenRouter) and Mock implementations
Models/     Shared value/persisted types used by every layer above
```

The dependency direction is strictly downward — `Domain/` never imports `Data/` or `Services/`, it just operates on plain `WardrobeItem`/`StyleConstraints` values passed in by whoever calls it (a view model). This is what keeps `Domain/PairCompatibilityScoring.swift` mockable and 100%-testable per CLAUDE.md §4: every test in `Vision_clotherTests/` constructs its own `WardrobeItem`s and calls the pure functions directly, with no SwiftData container and no network involved.

## App entry, onboarding & navigation

`Vision_clotherApp`'s `WindowGroup` hosts `Features/Root/AppRootView`, which wraps `RootTabView` (the 5-tab shell) and adds two app-level concerns:

- **First-run onboarding** (`Features/Onboarding/OnboardingFlowView`): presented as a `.fullScreenCover` when the user is genuinely not set up — `!hasCompletedOnboarding && (no portrait OR empty non-ghost closet)`, evaluated once per launch. Keyed on real state so a returning/Cloud-Sync-restored user never sees it and no step traps the user (portrait has a default-silhouette escape hatch, the rest are skippable). It *reuses* the real setup flows (`ProfileViewModel` portrait pipeline, `AddItemView`, `SwipeDiscoveryView`) rather than reimplementing them.
- **Navigation state** (`Features/Root/AppNavigator`, injected app-wide): owns the selected tab (`RootTabView` uses `TabView(selection:)` with per-tab `.tag`) and a one-shot `pendingDailyOutfit` flag. The Outfit-of-the-Day daily reminder (`AppWiring/DailyOutfitReminder`, an idempotent 8am `UNCalendarNotificationTrigger` scheduled from `AppRootView` once the closet is non-empty) routes its tap through `NotificationDelegate.onDailyOutfitTapped` → `AppNavigator.requestDailyOutfit()`, which switches to the Daily Assistant; `DailyAssistantView` consumes the flag and auto-runs `askForTodaysOutfit()`. Job-completion notification taps still route separately to the Activity panel.

## Motion & the design system

`Vision_clother/Vision_clother/DesignSystem/` holds the shared visual vocabulary — `VCSpacing`, `VCRadius`, `VCAccentColor`, `VCShadow`/`vcShadow()`, `premiumCard()`, `VCChartPalette`, `PrimaryButtonStyle`/`SecondaryButtonStyle`, `CachedWardrobeImage`, `ZoomableImageContainer`, `VCLoadingStageView` — plus `VCMotion.swift`, which is the single source of animation timing for the whole client (2026-07-26 pass).

Rules:

- **No view declares its own animation literal.** Every animation resolves to a `VCMotion` token (`interactive`, `standard`, `contentFade`, `entrance`, `gesture`, `commit`) and, where a view enters or leaves, a `VCTransition` shape (`card`, `message`, `pop`, `lateral(forward:)`). A stray `.spring(...)`/`.easeInOut(...)` in a feature file is a bug — grep for animation literals outside `VCMotion.swift` and there should be none.
- **Use `.vcAnimation(_:value:)`, never SwiftUI's `.animation(_:value:)`.** It reads `accessibilityReduceMotion` inside the modifier, so Reduce Motion is honored app-wide without every call site remembering to check. Imperative `withAnimation` sites pass their token through `vcMotion(_:reduceMotion:)` with the view's own `@Environment(\.accessibilityReduceMotion)`.
- **Anchor `.vcAnimation` to a container that survives the change it's watching**, not to the `Group` whose branches are swapping. When a state change should animate a branch swap, prefer mutating the state inside an explicit `withAnimation` — that removes any ambiguity about whether an animation is in scope when the transition runs.
- **Transitions must carry movement.** Opacity-only crossfades between surfaces that share a background are invisible at any duration; that is what made the first (2026-07-25) motion pass read as "no animations anywhere" on device.
- **Scroll-driven motion beats state-keyed motion on browse screens.** `vcCarouselCardTransition()` (horizontal, outfit carousels) and `vcScrollEntrance()` (vertical, Closet grid) wrap `.scrollTransition` so content animates continuously as the user scrolls, rather than only on the rare insert/delete. Both read the Reduce Motion flag out of the environment *before* the transition closure, which is non-isolated and cannot reference a main-actor property.
- **Tab-to-tab content transitions are deliberately not customized** — `RootTabView` uses `TabView(selection:)` and a custom transition there fights the system tab bar.

## Persistence (CLAUDE.md guardrail #3 — SwiftData)

- `Models/WardrobeItem.swift`, `Models/FeedbackEvent.swift`, `Models/SavedCombination.swift`, `Models/UserStyleProfile.swift` — `@Model` classes.
- `Data/WardrobeRepository.swift` — the `WardrobeRepository` protocol (marked `@MainActor` to match `SwiftDataWardrobeRepository`'s isolation) and its SwiftData-backed implementation. Every view model takes a `WardrobeRepository`, never a concrete `ModelContext`, so the storage technology could change later without touching `Domain/` or `Features/`.
- `Vision_clotherApp.swift` registers the model container from `SchemaV18.models` (the current head — bump both this and the migration plan's `schemas`/`stages` when adding an entity), covering `WardrobeItem`, `OutfitFeedback`, `ItemFeedback`, `PairFeedback`, `SavedCombination`, `ItemRating`, `UserStyleProfile`, `SessionSummary`, `ItemNote`, and the swipe/analytics tables.
- `Models/SessionSummary.swift` is compressed cross-session memory (session-summary feature, `docs/decisions/resolved-v1.md`) — a short LLM-written recap of one Daily Assistant conversation, piggybacked onto the recommendation call's existing structured response rather than a separate call. Bounded rolling retention (`Data/WardrobeRepository.swift`'s `pruneOldSessionSummaries`, last 5 kept), last 2-3 injected into `Domain/StylistBrain.swift`'s recommendation prompt only.
- `UserStyleProfile` is deliberately a single-row SwiftData model (queried, upserted via `WardrobeRepository.saveUserProfile`) rather than a disk file like `UserPortraitStorage` — it's structured data the Profile tab renders, with no image blob to store.
- `Models/ItemNote.swift` (Item-Level Feedback, `SchemaV18`) is the user's own short notes about one garment ("runs loose", "not warm enough") — **the only mutable feedback model in the app**, since a note is a current-state claim the user edits/deletes in Closet rather than history feeding a decayed aggregate. Read by `Domain/WardrobeCatalogBuilder.swift` (`CatalogEntry.userNote` for `conditional` notes; `blocking` notes drop the item from the catalog entirely) and by `OutfitRecommendationEngine.outfitScore`'s Item Suitability penalty. Written by `Domain/ItemFeedbackChip.swift`'s per-slot chips (`Features/Rating/RateCombinationView.swift`), by the user (`Features/Closet/ItemNotesSectionView.swift`), and by `Services/CombinationChemistryInferenceService.swift` reading their free-text outfit comment. Synced like any other entity — and the only mutable one, so `WardrobeSyncCoordinator.applyItemNoteChange`'s local-dirty guard genuinely matters.
- `Models/SwipeDiscovery.swift`'s `SwipeAttributeEvent` (Multi-Garment "Discover Your Style") is now one row per **detected garment** on a swiped photo, not one row per photo — a full-outfit swipe produces multiple rows, keyed `(sourcePhotoID, slot)`. `SwipeCombinationEvent` is a sibling table, one row per swiped photo that showed 2+ garments, carrying the whole-look color-harmony/style-coherence/formality-consistency signal (`Models/SceneMetadata.swift`). Both carry a 4-point `SwipeSentiment` (love/like/dislike/hate) rather than a flat liked/disliked bool; schema `V15 -> V16` (`Models/SchemaMigrations.swift`) is a `.custom` migration mapping legacy binary swipes to the moderate `.like`/`.dislike` values. Both tables are local-only (never synced), same posture as their V13-era predecessor.

### Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section)

Local SwiftData is a per-account cache/mirror, not the sole source of truth, once a user has signed in — Firestore + Cloud Storage hold the durable per-account copy.

- `Data/SyncingWardrobeRepository.swift` decorates `WardrobeRepository`, queuing a durable outbox write (`Models/SyncMetadata.swift`, drained by `Data/SyncOutboxWorker.swift`) alongside every local mutation. Every real call site constructs this, not `SwiftDataWardrobeRepository` directly.
- `Data/WardrobeSyncCoordinator.swift` reacts to `AuthService.shared.$uid` changes — bootstrap (push-local-up for a brand-new account, or wipe-and-pull for a returning one) and the foreground delta-reconcile safety net.
- `Data/Sync/FirestoreDTOs.swift` / `Services/WardrobeSyncService.swift` are the Firestore/Storage transport — direct client SDK calls gated by `backend/firestore.rules`/`backend/storage.rules`, no backend involvement.
- 10 of the 12 `@Model` types sync, including `SessionSummary`; `WardrobeItemEmbedding` and `RecommendationImpressionEvent` stay local-only (see the Cloud Sync decision doc for why). `VisualPreferenceStateDTO` still syncs, but since 2026-07-27 it carries only `totalSwipes` (the swipe-deck calibration counter) — the pixel-embedding centroid fields were dropped from the wire format with the rest of the retired visual engine. Firestore docs written by older builds still carry those keys; `Codable` ignores them on decode and the next push overwrites the doc.

## Networking (CLAUDE.md guardrails #1 and #2)

Swift has no official OpenRouter SDK, so every service is a raw `URLSession` call — all providers (intent extraction, vision tagging, recommendation, try-on rendering) go through OpenRouter, selected per call shape by `Config/ModelConfig.swift` (`textToText` / `imageToText` / `imageToImage` / `imageEdit`). All four are computed properties backed by Firebase Remote Config (`Config/RemoteConfigManager.swift`) rather than plain constants, so any of them can be hotfixed from the Firebase Console with no app build; `textToText` additionally has Remote-Config-backed payload knobs (`temperature`, `maxTokens`, `enableStrictJSONSchema`, `textToTextFallback`) scoped to its own call shape. See `docs/backend/conventions.md`'s "AI model hotfix via Firebase Remote Config" section for the full key table and procedure. `Prompts` (the system-prompt/instruction strings, same file) stays plain hardcoded text — out of scope for this hotfix path:

- `Services/OpenRouterIntentExtractionService.swift` — POSTs to OpenRouter's OpenAI-compatible `/chat/completions` endpoint with `response_format: json_schema` constraining the model to exactly PRD.md §3.3's `StyleConstraints` shape. One silent automatic retry on a decode/empty-response failure; network/HTTP failures surface to the UI for a manual retry.
- `Services/OpenRouterTryOnRenderService.swift` — a single synchronous POST (120s timeout) with the base portrait plus each non-ghost garment's image as base64 `image_url` parts. Two request shapes depending on `ModelConfig.isChatCompletionImageModel`: Gemini image models go to `/chat/completions` with `modalities: ["text", "image"]` (the current default, `google/gemini-3.1-flash-lite-image`); dedicated Images-API models (e.g. `bytedance-seed/seedream-4.5`) go to `/images`. There is no async submit/poll job — `TryOnState` still exposes `submitting` / `polling(elapsedSeconds:)` / `succeeded` / `failed` for the UI, but the real service only ever drives `.submitting` → `.succeeded`/`.failed`; `.polling` is only emitted by `MockTryOnRenderService`'s simulated staged delay. Images are downscaled to a 1280px max dimension client-side before encoding, since full-resolution camera captures were too large to upload inside the timeout.

Both are hidden behind a protocol (`IntentExtractionService`, `TryOnRenderService`) with a `Mock*` implementation used whenever no API key is configured (`Services/ServiceFactory.swift`) — so the app is fully interactive in Simulator with zero setup, and no test or `#Preview` ever depends on real network access or a real API key.

- `Services/VisionMetadataExtractionService.swift`'s `extractSceneMetadata(imageData:)` (Multi-Garment "Discover Your Style", used only by the swipe deck and `StyleCheckViewModel`) is a distinct call shape from `extractMetadata(imageData:focus:)` — it returns `Models/SceneMetadata.swift`'s `{ garments: [GarmentMetadata], combination: CombinationMetadata? }` (every distinct visible worn garment, plus a whole-look assessment only when 2+ are detected) rather than one flat `GarmentMetadata`. Same structured-output-with-unstructured-fallback shape and 400-status special case as `extractMetadata`, factored via a shared `garmentObjectSchema` JSON Schema fragment reused by both call shapes' wire schemas — but unlike the rest of this file's services (see `docs/approach/conventions.md`'s retry-behavior rule), both call shapes here try each mode (structured, unstructured) exactly once, no same-mode retry, and each request sets an explicit 55s `timeoutInterval` (a few seconds under the backend `proxyApi` function's own 60s timeout — a shorter 20s value was tried first and found to cut off calls that were genuinely still in flight, not stalled): `StyleCheckViewModel` blocks its UI synchronously on this call (`ProgressView("Analyzing…")`), so the full structured→unstructured fallback is capped at ~110s worst case (only if both attempts are unusually slow) instead of the up-to-four-attempts-at-60s-each shape used elsewhere. `Models/SceneMetadata.swift`'s decode is also tolerant of a single malformed garment in the array (dropped, not fatal to the whole response) since the unstructured-fallback path isn't schema-enforced by the API and a busy multi-garment photo has more chances for one field to drift out of its enum.

## API keys — dev-only posture

`Services/APIKeys.swift` reads from a bundled `Config/Secrets.plist`, which is gitignored (see `Config/README.md`). To bypass bundling limitations during simulator local development, it falls back to loading the file directly from the local absolute path `/Users/jaswanth/mydocs/ios-apps/vision_clother/Vision_clother/Vision_clother/Config/Secrets.plist` in debug mode. This means the app can call OpenRouter directly with an embedded key — acceptable for personal development, **not** for any distributed build. Before shipping to TestFlight/App Store, this needs to move behind a thin proxy backend that holds the key server-side (see `docs/backend/architecture.md`).

## LLM-as-Recommender pipeline (2026-07-10 reversal — PRD §2.1a)

`DailyAssistantViewModel.requestOutfitIdeas()` now tries a primary path before falling back to the original §2.1 flow:

```
prompt ─┬─> WardrobeCatalogBuilder.build(inventory)  ──┐
        │      (Domain/, bounded/text-only catalog)    │
        ├─> WardrobeRepository.fetchUserProfile()      ├─> OutfitRecommendationService
        │      (lazy-derives once from portrait if nil) │      (Services/, LLM call)
        └─> CurrentWeatherProviding.currentWeather() ───┘
                                                          │
                                                          ▼
                                          OutfitRecommendationValidator.validate
                                          (Domain/ — rejects unknown/wrong-slot/
                                           duplicate/Ghost ids, re-scores survivors
                                           via OutfitRecommendationEngine.outfitScore)
                                                          │
                                onEmpty/onThrow ──────────┼──────────> success
                                     │                                    │
                                     ▼                                    ▼
                    fallback: intentService.extractConstraints    candidates shown
                    + OutfitRecommendationEngine.generateCandidates
                    (original §2.1 flow, unchanged)
```

- `Services/OutfitRecommendationService.swift` / `Services/UserProfileDerivationService.swift` / `Services/WeatherProvider.swift` follow the same protocol + `Mock*` + `ServiceFactory` gate as every other network-facing service — the mock recommendation service reads the real catalog it's given and returns valid picks, so the keyless-Simulator path still exercises the validator with genuinely valid data.
- `OpenRouterOutfitRecommendationService`'s existing unstructured-JSON retry (triggered on an empty/malformed/rejected structured-output attempt) now also swaps from `ModelConfig.textToText` to `ModelConfig.textToTextFallback` — both Remote-Config-backed (`Config/RemoteConfigManager.swift`, keys `ai_primary_model_name`/`ai_fallback_model_name`), so a primary model that starts failing upstream can be routed around from the Firebase Console alone.
- `Services/RecommendationSettings.swift` — a `UserDefaults`-backed privacy toggle (`useAIRecommendations`, default `true`). When off, the primary path is skipped entirely and no catalog/profile leaves the device.
- The fallback engine (`Domain/OutfitRecommendationEngine.swift`) and its tests are untouched — the validator *calls* it for re-scoring, never modifies it, and it remains the deterministic floor when the LLM is unavailable.

## What's deliberately not built yet

- **Dedicated onboarding for base portrait capture.** The photo is captured the first time the user opens Manual Outfit Pairing (`Features/Pairing/ManualPairingView.swift` + `Services/UserPortraitStorage.swift`), not during a first-run onboarding flow. `DailyAssistantView`'s recommendation-engine try-on reads the same stored portrait.
- **Real WeatherKit integration.** `Services/WeatherProvider.swift`'s `WeatherKitWeatherProvider` is a placeholder that always returns `nil` — it needs the WeatherKit entitlement/capability added to the app target first. `ServiceFactory.makeWeatherProvider()` defaults to `MockCurrentWeatherProvider` so the app stays fully interactive without it; wiring the real provider is a follow-up.

## Saved combinations (Tab 4)

"Save this outfit?" (Manual Outfit Pairing) and the new Save button on Daily Assistant's try-on result both do two things now: record the existing feedback-table signal (`WardrobeRepository.recordPairFeedback`/`recordOutfitFeedback`), and durably persist the generated image itself.

- `Models/SavedCombination.swift` — `@Model`, denormalized (`topLabel`/`bottomLabel` strings, not just item IDs) so a row still renders if the source `WardrobeItem` is later deleted from the closet.
- The generated image bytes (loaded from the render service's ephemeral `.succeeded(imageURL:)` temp file) are written durably via the existing `Data/ImageStorage.swift` (same `Documents/`-backed boundary garment photos use), and `SavedCombination.imageAssetName` stores the returned filename.
- `WardrobeRepository.fetchSavedCombinations()` / `saveCombination(_:)` / `deleteCombination(_:)` — added to the single repository facade rather than a separate store, matching this layer's existing single-boundary convention.
- `Services/PhotoLibrarySaver.swift` — mirrors the saved image to the user's Photos library via `PHPhotoLibrary.requestAuthorization(for: .addOnly)` (no read access requested). On-device, no API key gate, same posture as `PersonPhotoValidationService`. A Photos-write failure is swallowed — the app-local save via `ImageStorage` has already succeeded by that point, so it's not treated as save failure.
- `Features/Combinations/` — the new Tab 4: `CombinationsView` (list + swipe-to-delete), `CombinationDetailView` (full-screen paging `TabView` over the saved set, swipe between them, toolbar delete), `CombinationsViewModel`.
- **Zoomable generated images:** `CombinationDetailPage`'s rendered image (and every other place a generated try-on render is shown full-size — `RateCombinationView`'s `combinationImage`, `TryOnResultView`'s `.succeeded` image, `ManualPairingView`'s preview) is wrapped in `DesignSystem/ZoomableImageContainer.swift`, a reusable pinch-to-zoom/double-tap-to-toggle/pan-while-zoomed view. It attaches its pan gesture via `.highPriorityGesture(_:including:)`, toggled inert (`.subviews`) vs. active (`.all`) based on zoom state, so a zoomed pan wins over `CombinationDetailView`'s ancestor `TabView` page-swipe (and `RateCombinationView`'s ancestor `List` scroll) right at the image's edges, while an unzoomed image leaves that ancestor gesture fully in control.

## Manual Outfit Pairing with AI Virtual Try-On

`Features/Pairing/ManualPairingView.swift` + `ManualPairingViewModel.swift`, entered from a toolbar action in `ClosetView`. Lets the user pick a top and bottom directly (Ghost Elements excluded — they have no backing photo file) rather than getting a scored `OutfitCombination` from the recommendation engine, and renders a try-on preview via the same `TryOnRenderService` the recommendation flow uses (`Services/OpenRouterTryOnRenderService.swift`, `ModelConfig.imageToImage`).

- `Services/UserPortraitStorage.swift` — the user's own full-body photo, one fixed file, not a SwiftData model.
- `Services/PersonPhotoValidationService.swift` — on-device Vision framework gate (single person, full-body landmarks, basic lighting) run before the portrait is ever sent to OpenRouter. Always real, no API key gate (`ServiceFactory.makePersonPhotoValidationService`), same posture as `makeBackgroundIsolationService`.
- `ManualPairingViewModel.State` (`idle`/`validatingPhoto`/`preparingImages`/`generatingPreview(TryOnStage)`/`success`/`failed`) drives the view; reselecting a top/bottom mid-generation cancels the in-flight `Task` and — since `Task.cancel()` is only cooperative — also checks a `currentGenerationID` token in the completion callback so a stale result can never land after a newer selection has started.
- "Save this outfit?" → Yes persists both the feedback rows and the generated image itself (see "Saved combinations (Tab 4)" above) — the preview is no longer discarded after a positive save.
