# CLAUDE.md — Vision Clother

Operational guide for Claude Code execution in this workspace.

## 1. Project Overview
Vision Clother is a mobile-first AI stylist providing scenario-based flatlay recommendations via a local deterministic rules engine and visual try-on layering.

**Core Invariant (revised 2026-07-14, sync scope revised 2026-07-16, Q&A scope added 2026-07-20):** The LLM is the sole outfit recommender. It receives the user's free-text prompt, a bounded catalog of wardrobe item *descriptions* (id, slot, formality, color/hex, undertone, pattern, seasonality, fabric weight, short description — never images at recommendation time), the user's derived style profile, weather, and color-theory guidance, and returns outfit picks that reference item IDs. A deterministic on-device validator (`Domain/OutfitRecommendationValidator.swift`) verifies every pick references a real, correctly-slotted, non-ghost item and re-scores survivors. If the catalog is empty, the API is unavailable, or validation yields nothing usable, the app surfaces an error message — there is no on-device fallback pipeline. Wardrobe photos now sync to the user's private Cloud Storage bucket (`users/{uid}/wardrobeImages/`) for cross-device/account continuity (see "Cloud Sync" in `docs/decisions/resolved-v1.md`) — but the recommendation LLM call itself still never receives images, only the text/hex catalog described above. See `docs/decisions/resolved-v1.md` for the full rationale and the prior (superseded) invariant.

The LLM is also the sole answerer of anything that should be answered in words rather than as a built outfit — factual questions about the user's own wardrobe/computed Insights (e.g. "what colors do I wear most", "what's my Style DNA") *and* general style/fashion/shopping advice that isn't grounded in the user's own data at all (e.g. "what should I buy to dress like an American man") — a second, deliberately separate and much smaller call (`Services/StylistQAService.swift` + `Domain/StylistQABrain.swift`), never folded into the recommendation prompt above. Only a concrete request to be dressed for a named occasion from real owned items (or a refinement of outfits already shown) falls through to the recommender. It's grounded in the same text-only wardrobe catalog plus a condensed Insights summary (`Domain/InsightsSummaryBuilder.swift`, reusing the same on-device aggregators as the Insights tab — Overview/Colors/Wardrobe/Shopping/Style DNA, not Trends) — also never images. `Domain/QuestionIntentHeuristic.swift` is a cheap on-device pre-filter, not the classifier: it only gates which turns even attempt this second call so an ordinary recommendation request pays nothing extra; the QA call itself decides and routes back to the recommender whenever a message isn't actually a wardrobe/Insights question. Both calls share the same server-side "recommendation" quota bucket (same proxy route, `backend/functions/src/app.ts` gates by path, not payload). See `docs/decisions/resolved-v1.md` for the full rationale.

**Item identity:** `WardrobeItem.id` (`Models/WardrobeItem.swift`) — a persisted, unique `UUID` — is the single stable identifier for a wardrobe item across the entire app. It is the same ID used in persistence, feedback/rating records, the LLM catalog (`Domain/WardrobeCatalogBuilder.swift`'s `CatalogEntry.id`), the LLM's picks (`Models/OutfitRecommendationResponse.swift`'s `RecommendedOutfitWire.*_id` fields), and the resolved `OutfitCombination` the UI renders (`Domain/OutfitRecommendationValidator.swift` maps IDs back to the real `WardrobeItem`). Never introduce a second/short ID — always reference an item by this UUID, and always render the full `WardrobeItem` (photo via `imageAssetName` + `ImageStorage`, `displayLabel`) rather than reducing it to `colorProfile` alone.

## 2. Dev Build & Test Commands

### iOS Client (SwiftUI) — the only build target for V1
The Xcode project lives at the repo root.
* **Build:** `xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build`
* **Test:** Do not test the application, the tests are taking more resources than what the system can handle. So skip tests for now. 

## 3. Reference Docs
Read the relevant doc **before** modifying a layer:
* Structural specs & metadata/rules: `PRD.md`
* iOS layer architecture & persistence: `docs/ios/architecture.md`
* Domain vocabulary (slots, formality, ghost elements, scoring): `docs/domain/vision-clother-concepts.md`
* Coding conventions (testing, error handling, wire schemas, API keys): `docs/approach/conventions.md`
* V1 resolved decisions (LLM driver, diffusion provider, state store): `docs/decisions/resolved-v1.md`
* Stylist Intelligence Engine — Decision Hierarchy tiers, resolved-constraints self-report, symmetric taste injection, validator reason codes: `docs/decisions/stylist-intelligence-engine.md`

## 4. Key Invariants (Details in Subdirectory CLAUDE.md Files)
* **Schema bounds:** Explicit `CodingKeys` on all wire types — see `Models/CLAUDE.md`
* **Scoring isolation:** `Domain/PairCompatibilityScoring.swift` is mockable, NaN-safe, ghost-element-identical — see `Domain/CLAUDE.md`
* **Async boundaries:** `OpenRouterTryOnRenderService` drives a single bounded-timeout request through explicit `TryOnState`, never a bare unbounded loop — see `Services/CLAUDE.md`

## 5. Workflow & COding rulesRules
* Always propose a plan before making changes to 3+ files.
* Run `xcodebuild clean build` after every implementation task.
* Use Swift Testing framework (`import Testing`, `@Test`, `#expect`), not XCTest.
* **Logging:** When implementing any new feature, service, or repository mutation, you must explicitly implement logging. Follow the unified project telemetry string pattern exactly (e.g., using `[AI-Stylist-ML]`, `[SyncOutbox]`, or similar localized subsystems) to ensure matching observability across the codebase.

## 6. Update & Consult Timeline
* **Read Before Coding:** Always read `timeline.md` at the start of a task to understand the chronological context, recent architectural changes, schema evolution, and how prior changes were implemented.
* **Update After Coding:** Every time you implement a new feature or fix a bug, make sure to update `timeline.md` with the date, status, problem statement, and precise file changes. This allows the user to see the history and helps you maintain context across turns.

