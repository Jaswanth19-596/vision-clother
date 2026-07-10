# Domain Concepts

The vocabulary below is shared across the LLM's constraint output, the wardrobe item schema, and the on-device scoring engine — see `PRD.md` §3.1 and §3.3 for the original spec this was implemented from.

## Slots

Every garment belongs to exactly one of four slots (`Models/WardrobeItem.swift`'s `Slot` enum): `top`, `bottom`, `footwear`, `outerwear`. An `OutfitCombination` always has the first three; `outerwear` is optional and only included when `StyleConstraints.weatherLayeringRequired` is true.

## Formality score

A `Double` from 1.0 (loungewear/gym) to 5.0 (black tie), per item. `StyleConstraints.formalityRange` is a `[min, max]` band the LLM extracts from the user's scenario; the recommendation engine filters candidates against it with a small tolerance (±0.5) rather than an exact match, since real wardrobes rarely have an item at a precise formality value.

## Color vibe

One shared enum (`ColorVibe`) used both for a garment's `color_profile.category` and for the LLM's `color_palette_vibe` output: `neutral`, `earth_tones`, `monochrome`, `vibrant`, `pastel`. Reusing one enum for both sides means the aesthetic-prior scoring function (below) can compare a constraint's palette directly against an item's category without a translation layer.

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
