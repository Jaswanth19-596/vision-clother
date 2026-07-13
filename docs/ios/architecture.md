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
            + real (OpenRouter/Fal) and Mock implementations
Models/     Shared value/persisted types used by every layer above
```

The dependency direction is strictly downward — `Domain/` never imports `Data/` or `Services/`, it just operates on plain `WardrobeItem`/`StyleConstraints` values passed in by whoever calls it (a view model). This is what keeps `Domain/PairCompatibilityScoring.swift` mockable and 100%-testable per CLAUDE.md §4: every test in `Vision_clotherTests/` constructs its own `WardrobeItem`s and calls the pure functions directly, with no SwiftData container and no network involved.

## Persistence (CLAUDE.md guardrail #3 — SwiftData)

- `Models/WardrobeItem.swift`, `Models/FeedbackEvent.swift`, `Models/SavedCombination.swift`, `Models/UserStyleProfile.swift` — `@Model` classes.
- `Data/WardrobeRepository.swift` — the `WardrobeRepository` protocol (marked `@MainActor` to match `SwiftDataWardrobeRepository`'s isolation) and its SwiftData-backed implementation. Every view model takes a `WardrobeRepository`, never a concrete `ModelContext`, so the storage technology could change later without touching `Domain/` or `Features/`.
- `Vision_clotherApp.swift` registers the model container for `WardrobeItem`, `OutfitFeedback`, `ItemFeedback`, `PairFeedback`, `SavedCombination`, `ItemRating`, `UserStyleProfile`.
- `UserStyleProfile` is deliberately a single-row SwiftData model (queried, upserted via `WardrobeRepository.saveUserProfile`) rather than a disk file like `UserPortraitStorage` — it's structured data the Profile tab renders, with no image blob to store.

## Networking (CLAUDE.md guardrails #1 and #2)

Swift has no official OpenRouter or Fal SDK, so both services are raw `URLSession` calls:

- `Services/OpenRouterIntentExtractionService.swift` — POSTs to OpenRouter's OpenAI-compatible `/chat/completions` endpoint with `response_format: json_schema` constraining the model to exactly PRD.md §3.3's `StyleConstraints` shape. One silent automatic retry on a decode/empty-response failure; network/HTTP failures surface to the UI for a manual retry.
- `Services/FalTryOnRenderService.swift` — Fal's async submit → poll-status → fetch-result queue pattern, driving an explicit `TryOnState` (`submitting` / `polling(elapsedSeconds:)` / `succeeded` / `failed`) rather than a bare `async throws`. Poll cadence backs off from 1s to a 3s cap; total budget is 45s before it gives up as `.timedOut`.

Both are hidden behind a protocol (`IntentExtractionService`, `TryOnRenderService`) with a `Mock*` implementation used whenever no API key is configured (`Services/ServiceFactory.swift`) — so the app is fully interactive in Simulator with zero setup, and no test or `#Preview` ever depends on real network access or a real API key.

## API keys — dev-only posture

`Services/APIKeys.swift` reads from a bundled `Config/Secrets.plist`, which is gitignored (see `Config/README.md`). To bypass bundling limitations during simulator local development, it falls back to loading the file directly from the local absolute path `/Users/jaswanth/mydocs/ios-apps/vision_clother/Vision_clother/Vision_clother/Config/Secrets.plist` in debug mode. This means the app can call OpenRouter/Fal directly with an embedded key — acceptable for personal development, **not** for any distributed build. Before shipping to TestFlight/App Store, this needs to move behind a thin proxy backend that holds the keys server-side (see `docs/backend/architecture.md`).

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

## Manual Outfit Pairing with AI Virtual Try-On

`Features/Pairing/ManualPairingView.swift` + `ManualPairingViewModel.swift`, entered from a toolbar action in `ClosetView`. Lets the user pick a top and bottom directly (Ghost Elements excluded — they have no backing photo file) rather than getting a scored `OutfitCombination` from the recommendation engine, and renders a try-on preview via the same `TryOnRenderService` the recommendation flow uses (`Services/FalTryOnRenderService.swift`, `fal-ai/fashn/tryon/v1.6`).

- `Services/UserPortraitStorage.swift` — the user's own full-body photo, one fixed file, not a SwiftData model.
- `Services/PersonPhotoValidationService.swift` — on-device Vision framework gate (single person, full-body landmarks, basic lighting) run before the portrait is ever sent to Fal. Always real, no API key gate (`ServiceFactory.makePersonPhotoValidationService`), same posture as `makeBackgroundIsolationService`.
- `ManualPairingViewModel.State` (`idle`/`validatingPhoto`/`preparingImages`/`generatingPreview(TryOnStage)`/`success`/`failed`) drives the view; reselecting a top/bottom mid-generation cancels the in-flight `Task` and — since `Task.cancel()` is only cooperative — also checks a `currentGenerationID` token in the completion callback so a stale result can never land after a newer selection has started.
- "Save this outfit?" → Yes persists both the feedback rows and the generated image itself (see "Saved combinations (Tab 4)" above) — the preview is no longer discarded after a positive save.
