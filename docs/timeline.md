# Timeline

History of features and fixes, newest first. Kept up to date per `CLAUDE.md` §6 so a future session can see what shipped and why without re-deriving it from `git log`.

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
