# Domain Concepts

The vocabulary below is shared across the LLM's constraint output, the wardrobe item schema, and the on-device scoring engine — see `PRD.md` §3.1 and §3.3 for the original spec this was implemented from.

## Slots

Every garment belongs to exactly one of four slots (`Models/WardrobeItem.swift`'s `Slot` enum): `top`, `bottom`, `footwear`, `outerwear`. An `OutfitCombination` always has the first three; `outerwear` is optional and only included when `StyleConstraints.weatherLayeringRequired` is true.

## Formality score

A `Double` from 1.0 (loungewear/gym) to 5.0 (black tie), per item. `StyleConstraints.formalityRange` is a `[min, max]` band the LLM extracts from the user's scenario; the recommendation engine filters candidates against it with a small tolerance (±0.5) rather than an exact match, since real wardrobes rarely have an item at a precise formality value.

## Color vibe

One shared enum (`ColorVibe`) used both for a garment's `color_profile.category` and for the LLM's `color_palette_vibe` output: `neutral`, `earth_tones`, `monochrome`, `vibrant`, `pastel`. Reusing one enum for both sides means the aesthetic-prior scoring function (below) can compare a constraint's palette directly against an item's category without a translation layer.

Since the 2026-07-10 LLM-as-Recommender reversal (`docs/decisions/resolved-v1.md`), `ColorProfile` also carries an optional `undertone` (`warm`/`cool`/`neutral`) — see "Color theory" below. It's optional purely for migration safety (older persisted rows have no `undertone` key and decode as `nil`); the coarse `ColorVibe` category remains the fallback signal whenever hex/undertone data is unavailable.

## Color theory (`Domain/ColorHarmony.swift`)

Real hue-based color theory, replacing the old flat `-0.2` "both vibrant" penalty in `PairCompatibilityScoring.aestheticPrior`. Operates on the hex values every `WardrobeItem.colorProfile` already carries (`primaryHex`), which were previously captured at ingestion but never used for scoring:

- `hsl(fromHex:)` parses `#RRGGBB` into hue/saturation/lightness; malformed hex returns `nil` — never crashes, never NaNs.
- `harmonyScore(_:_:)` rewards **complementary** (~180° hue apart) and **analogous/monochrome** (<40° apart) pairings, and penalizes the **muddy mid-hue clash zone** (60°–150° apart), scaled up by how saturated both colors are. Either color being near-achromatic (gray/white/black) always scores as a safe pairing — neutrals anchor any outfit regardless of the other hue.
- `undertoneCompatibility(_:_:)` scores `warm`/`cool`/`neutral` pairs, with `nil` on either side reading as "no signal" (neutral 0.5), never a penalty.
- **Graceful degrade**: when either item's hex is unparseable, `aestheticPrior` falls back to the original coarse `ColorVibe`-category check — real color-theory scoring and the old category check are never both applied, and there's always a valid score either way.

Color theory is applied in **two places**: as prompt guidance to the primary recommendation LLM (see below), and as this deterministic module inside `aestheticPrior` — used both by the fallback engine and by the validator's re-scoring pass, so an outfit is chromatically sane on every path, LLM-reachable or not.

## User Style Profile & recommendation LLM (PRD §2.1a, §3.7, §3.8)

The **2026-07-10 LLM-as-Recommender reversal** changed the core invariant: the LLM is now the primary outfit recommender, not just a constraint extractor. Full rationale in `docs/decisions/resolved-v1.md`; summary of the moving pieces:

- **`Domain/WardrobeCatalogBuilder.swift`** builds the bounded, text-only payload sent to the recommendation LLM: one compact `CatalogEntry` per real (non-Ghost) item — id, slot, formality, color category/hex/undertone, pattern, seasonality, fabric weight, a truncated description. Capped at `maxItems` (default 150) with slot-balanced sampling if the closet is larger, so payload size and cost stay bounded regardless of wardrobe growth. Garment *images* are never sent at recommendation time — only this text catalog.
- **`Services/OutfitRecommendationService.swift`** sends the user's prompt + catalog + `UserStyleProfile` + weather + color-theory guidance to the LLM (`temperature: 0`), which returns up to 5 outfit picks referencing catalog item IDs plus a short rationale each.
- **`Domain/OutfitRecommendationValidator.swift`** is the deterministic trust boundary: every returned id must resolve to a real, correctly-slotted, non-Ghost item, with no id reused across slots in the same outfit — anything else is dropped. Survivors are re-scored with the same `OutfitRecommendationEngine.outfitScore` the fallback path uses, so ranking stays consistent regardless of which path produced the outfit.
- **Fallback**: if the recommendation call throws or validation yields zero outfits, `DailyAssistantViewModel` falls back to the original §2.1 pipeline (intent extraction → `OutfitRecommendationEngine.generateCandidates`) unchanged — the deterministic engine is a permanent floor, not something this feature replaces.
- **`Models/UserStyleProfile.swift`** — a single-row SwiftData profile (skin tone, undertone, body type, style keywords, recommended/avoid colors) derived once from the existing onboarding portrait via `Services/UserProfileDerivationService.swift`, not re-sent per recommendation request. This is the only recommendation-adjacent call that sends an image.
- **Privacy**: a user-facing toggle (`RecommendationSettings.useAIRecommendations`) forces the fully deterministic path, skipping the recommendation call (and the catalog/profile it would send) entirely.

## Ghost Elements (PRD §3.2)

If a slot has zero real items, `Domain/GhostElementProvider.swift` injects a default placeholder garment (a white tee, black jeans, white sneakers, or a neutral jacket) so the recommendation engine — and the Closet grid — never see an empty slot. This is a deliberate onboarding-friction reducer: a brand-new user with an empty wardrobe still gets real, complete outfit suggestions on day one.

**Ghost elements are scored through the exact same code path as real items** — `Domain/PairCompatibilityScoring.swift` has no `isGhostElement` branch anywhere. The aesthetic-prior function is rule-based (formality delta, pattern clash, color-vibe clash) and works identically regardless of provenance; the item-preference term is already neutral for ghost items since no feedback history can exist for them. `isGhostElement` exists purely so the UI (`OutfitCardView`, `ClosetView`) can show a "Starter Piece" badge — the score itself is never faked or penalized for it.

## Mathematical Pair-Compatibility Scoring (PRD §3.4 — with a bug fix)

The PRD's original formula:

```
Score_Total = P(Pair_A,B | History) + Preference(Item)

P(Pair_A,B | History) = (w0 · Score_AestheticPrior + ΣFeedback) / (w0 + N)
```

where `ΣFeedback` sums `+1.0` per logged like and `−1.0` per logged dislike.

**Problem**: `Score_AestheticPrior` is bounded `[0, 1]`, but `ΣFeedback` is bounded `[−N, +N]`. Summing a `[0,1]` quantity with a `[−N,+N]` quantity and dividing by `(w0 + N)` does **not** stay in `[0,1]` — with enough dislikes it goes negative; with enough likes it can exceed 1. That breaks any downstream code that treats the result as a probability (e.g. averaging it with other pair scores, per below).

**Fix, as implemented in `Domain/PairCompatibilityScoring.swift`**: feedback is normalized to `[0, 1]` before summing — each liked pairing contributes `1.0`, each disliked pairing `0.0` (not `±1`). With that change, `P(Pair|History)` is a weighted average of two `[0,1]` quantities (`w0` parts prior, `N` parts feedback), so it's mathematically guaranteed to stay in `[0,1]` — while preserving exactly the `w0`-shrinkage behavior the PRD intended (a single extreme feedback event still can't overwhelm the prior when `w0 = 3.0`).

`Preference(Item)` uses the same shrinkage shape, seeded at a neutral `0.5` prior (an item has no rule-based aesthetic signal the way a *pair* does, so "no feedback yet" means "no opinion," not "assume compatible").

**Outfit-level aggregation** (not specified in the PRD, since it only describes pair scoring): `Domain/OutfitRecommendationEngine.outfitScore(for:history:)` computes `mean(pairwise P(Pair|History) over every pair in the outfit) + mean(Preference(Item) over every item in the outfit)`. Both means guard against an empty input (returning `0` rather than dividing by zero), which is what makes the engine safe to call on a 1-item or even 0-item list.

**NaN immunity** (CLAUDE.md §4's hard requirement): every division in this module is guarded. `pairCompatibilityScore`'s denominator is `priorWeight + evaluationCount`; even if a caller passes `priorWeight: 0` with zero history, the function falls back to the raw prior instead of computing `0/0`. See `Vision_clotherTests/PairCompatibilityScoringTests.swift` for the tests that pin this down.

## Three-Tier Feedback (PRD §3.6)

Persisted as three independent SwiftData models (`Models/FeedbackEvent.swift`), because each tier is queried differently by the engine and the Analytics tab:

- **`OutfitFeedback`** — did the overall look work? (binary, per `OutfitCombination.id`)
- **`ItemFeedback`** — per-garment fit/comfort assessment
- **`PairFeedback`** — did *this specific* top+bottom (etc.) combination work together? This is the `ΣFeedback` input to the pair-compatibility formula above. Stored order-independently (the smaller UUID string always goes in `itemAID`) so a lookup for `(A, B)` matches history recorded as `(B, A)`.
