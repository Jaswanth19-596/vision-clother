# CLAUDE.md — Vision Clother

Operational guide for Claude Code execution in this workspace.

## 1. Project Overview
Vision Clother is a mobile-first AI stylist providing scenario-based flatlay recommendations via a local deterministic rules engine and visual try-on layering.

**Core Invariant (revised 2026-07-14, sync scope revised 2026-07-16):** The LLM is the sole outfit recommender. It receives the user's free-text prompt, a bounded catalog of wardrobe item *descriptions* (id, slot, formality, color/hex, undertone, pattern, seasonality, fabric weight, short description — never images at recommendation time), the user's derived style profile, weather, and color-theory guidance, and returns outfit picks that reference item IDs. A deterministic on-device validator (`Domain/OutfitRecommendationValidator.swift`) verifies every pick references a real, correctly-slotted, non-ghost item and re-scores survivors. If the catalog is empty, the API is unavailable, or validation yields nothing usable, the app surfaces an error message — there is no on-device fallback pipeline. Wardrobe photos now sync to the user's private Cloud Storage bucket (`users/{uid}/wardrobeImages/`) for cross-device/account continuity (see "Cloud Sync" in `docs/decisions/resolved-v1.md`) — but the recommendation LLM call itself still never receives images, only the text/hex catalog described above. See `docs/decisions/resolved-v1.md` for the full rationale and the prior (superseded) invariant.

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

## 5. Workflow Rules
* Always propose a plan before making changes to 3+ files.
* Run `xcodebuild clean build` after every implementation task.
* Use Swift Testing framework (`import Testing`, `@Test`, `#expect`), not XCTest.

## 6. Update Timeline
* Every time you implement a new feature or fix a bug, make sure to update the timeline.
* The timeline allows the user to see the history of changes and the status of each feature.
* It also helps you understand the context of the codebase and plan the next feature.

