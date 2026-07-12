# Timeline

History of features and fixes, newest first. Kept up to date per `CLAUDE.md` §6 so a future session can see what shipped and why without re-deriving it from `git log`.

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
