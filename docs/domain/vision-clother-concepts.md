# Domain Concepts

The vocabulary below is shared across the LLM's constraint output, the wardrobe item schema, and the on-device scoring engine — see `PRD.md` §3.1 and §3.3 for the original spec this was implemented from.

## Slots

Every garment belongs to exactly one of seven slots (`Models/WardrobeItem.swift`'s `Slot` enum): `top`, `bottom`, `footwear`, `outerwear`, `headwear`, `accessory`, `bag` — the last three added 2026-07-14 to extend the app from a top/bottom/footwear stylist toward a fully "top to bottom" one. `accessory` is deliberately a single slot covering belt/scarf/tie/watch/sunglasses (one signature piece per outfit, not several simultaneously) rather than a slot per accessory type; jewelry is folded into `accessory` too rather than given its own slot, kept simple for V1.

Two per-slot properties on `Slot` encode the behavioral differences that used to be ad hoc `case .outerwear:` special-casing scattered across the codebase — any new slot should extend these rather than reintroducing that pattern:

- **`isRequired`**: `true` only for `top`/`bottom`/`footwear`. An `OutfitCombination` always has these three; every other slot (`outerwear`, `headwear`, `accessory`, `bag`) is optional and conditionally included — `outerwear` by `StyleConstraints.weatherLayeringRequired`, the three newer accents by `StyleConstraints.desiredAccentSlots` (populated by the recommendation LLM's self-reported `resolved_constraints`, same mechanism as `weatherLayeringRequired`).
- **`hasGhostDefault`**: whether `GhostElementProvider` backfills an empty instance of the slot — `true` for the original four, `false` for `headwear`/`accessory`/`bag` (see "Ghost Elements" below for why).

`OutfitCombination`, `RecommendedOutfitWire`, and `SavedCombination` are all slot-keyed (`[Slot: WardrobeItem]` / `[Slot: String]` / `[Slot: UUID]`) rather than having one named field per slot, specifically so adding a future category is a new `Slot` case plus the two properties above, not a multi-file field addition. `RecommendedOutfitWire` still presents a fixed `{slot}_id` property per slot on the wire (OpenRouter's strict JSON-schema mode requires an enumerable `properties` list, not a truly dynamic object) — the dictionary shape is achieved via a custom `Codable` implementation keyed by `Slot.wireKey`, not a schema change.

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

## Decision Hierarchy & resolved constraints (Stylist Intelligence Engine ADR)

`Domain/StylistBrain.swift`'s `DecisionHierarchy` is the 6-tier priority order a stylist reasons in — hard constraints, dress code, weather, preferences (intrinsic profile + learned ratings/affinities), visual cohesion, aesthetic trend — and it's **lexicographic, not blended**: a lower-numbered tier always dominates a higher one, so an outfit that violates the dress code is a wrong answer regardless of how good its color harmony is. Color harmony and fit/silhouette are merged into the single "visual cohesion" tier (2026-07-14 prompt restructure) since both are `.penalize`-enforced and can trade off against each other rather than being rigidly ordered. Each tier declares an `enforcement` (`.reject` for the validator's hard structural checks, `.penalize` for a scoring term, `.guide` for prompt-only guidance that may only break ties among otherwise-equal outfits — tier 6, aesthetic trend, is the only `.guide` tier). Dress code (tier 2) explicitly gates accent slots (bag/headwear/accessory) too, not just required garments — an accent item must clear the same formality bar, and the prompt must omit an accent slot rather than force in a mismatched item.

Numeric thresholds that both the prompt prose and the deterministic scorer need to agree on (currently: the formality-mismatch deltas) live once in `Domain/FashionKnowledgeConstants.swift`, referenced by both `StylistBrain`'s prompt text and `PairCompatibilityScoring.aestheticPrior` — this is the anti-drift mechanism: change the constant and both projections change together.

**Resolved constraints, self-reported (not a second LLM call):** the primary recommendation call now asks the model to also populate a top-level `resolved_constraints` field (`OutfitRecommendationResponse.resolvedConstraints`, same `StyleConstraints` shape the fallback intent-extraction call produces) reflecting what it resolved the scenario's dress code/weather/season to be. `DailyAssistantViewModel` threads this into `OutfitRecommendationValidator.validate(...)`, so Tier 1 (dress code) formality alignment is now enforced on the LLM path too — previously `constraints: nil` was passed there, so that penalty was inert and formality was only ever prompt guidance. This is deliberately *not* a call to `IntentExtractionService` before the recommendation request: the AI happy path must never engage the fallback pipeline's intent-extraction call (see `DailyAssistantViewModelTests.happyPathUsesRecommendationServiceAndSkipsTheFallbackEngine`), so the resolved constraints are produced by the same single LLM call that picks the items, not a second round-trip.

`Domain/OutfitRecommendationValidator.swift` also exposes `validateVerbose(...)`, which returns a `RejectionReason` (`.unknownID`, `.wrongSlot`, `.duplicateID`, `.ghostElement`, each tagged with the slot) per dropped wire outfit alongside the same validated/scored result `validate(...)` returns — previously a rejected pick was silently dropped by a `compactMap` with no record of why. Not yet wired to any UI or telemetry sink; it exists so future debugging/telemetry work doesn't have to guess why the LLM path yielded nothing.

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

**Headwear/accessory/bag deliberately get no ghost default** (`Slot.hasGhostDefault == false`). Ghost Elements exist to guarantee the *core* outfit silhouette always renders for a brand-new user — an outfit is still complete without a hat, so there's no completeness gap to backfill for these three. There's also no universally-neutral placeholder the way "white tee" is for a core slot — a generic ghost bag or pair of sunglasses would read as arbitrary rather than helpful. And permanently ghost-populating them would clutter `ClosetView` with "Starter Piece" tiles a user could never earn away from. `ClosetView` still shows a section for these slots for discoverability, with a real "add your first..." empty state instead of a ghost tile when the user owns none.

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

### Item Rating Score (Closet UI)

`Domain/ItemRatingScoring.swift`'s `score(for:history:) -> Int` is the 0-100 rating shown per item in `ClosetView`'s grid badge and `ItemDetailView`'s metadata row (added post-V1). It aggregates feedback from every source that references the item — not a new formula, just new plumbing on top of what already existed:

- Starts from `FeedbackHistory.itemFeedback[itemID]` (decay-weighted likes/total, already folding in `ItemRating`, `ItemFeedback`, and `OutfitFeedback.favoriteItemID`/`weakestItemID` — see `Data/WardrobeRepository.swift`'s `fetchFeedbackHistory()`).
- Adds `FeedbackHistory.pairFeedback` entries where the item is either side of the `PairKey` (Manual Pairing's "liked together" signal, previously only used for pair-compatibility scoring, not folded into any single item's tally).
- Feeds the summed likes/total straight into `PairCompatibilityScoring.itemPreference` (the same Bayesian-shrinkage function `OutfitRecommendationEngine.outfitScore` already uses internally) and scales the `[0,1]` result ×100.
- Returns `50` — not `nil` — when the item has no feedback from any source: `itemPreference`'s neutral-prior default *is* the intended rating for a freshly uploaded item (revised 2026-07-12 — an earlier version rendered a "Not yet rated" placeholder for `nil` instead, which also meant `Domain/WardrobeCatalogBuilder.swift`'s LLM-facing `user_rating` field sent `null` for these items, and the LLM recommender was observed avoiding them entirely rather than treating them as neutral).

This score is computed fresh on each view appearance (no persisted/cached field on `WardrobeItem`, no SwiftData migration) — consistent with how `ProfileView` already treats `FeedbackHistory` as transient, recomputed state.

### Taste Synthesis (Profile tab, 2026-07-13)

`Domain/TasteSynthesis.swift` turns the numeric affinity maps `AttributePreferenceProfile` already computes into a short, ranked list of `TasteSignal` values for the Profile tab's "Your Taste, In Words" section — e.g. "You gravitate toward earth tones for tops," "Smart-casual is your sweet spot." This is a **presentation-layer redesign, not a new preference model**: no ML, no training, no new scoring formula. `TasteSynthesis.rank(from:limit:)` is pure ranking/filtering —

- Only surfaces an attribute at or above a confidence threshold (`0.58`) as a positive signal, or at/below a lower threshold (`0.40`) as one "tends to avoid" signal — mirrors the symmetric like/dislike surfacing `StylistBrain`'s prompt composer already does for the recommendation LLM.
- Draws from `colorVibeAffinityBySlot`, `formalityAffinity`, `patternAffinity`, `styleTagAffinity`, `silhouetteAffinity`, and `fabricWeightAffinity` — the last three were already computed for recommendation scoring but never surfaced in any UI before this.
- Ranks candidates by distance from the neutral `0.5` prior, so the most confident signals surface first; an empty or sparse profile yields `[]`, never a fabricated statement.

English copy per signal lives in `Features/Profile/ProfileView.swift`, not in Domain — `TasteSignal` carries only structured data (slot/vibe/band/affinity), per `Domain/CLAUDE.md`'s no-UI-imports rule.
