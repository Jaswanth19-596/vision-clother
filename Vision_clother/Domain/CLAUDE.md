# Domain Layer

Pure business logic. No UIKit/SwiftUI imports.
- PairCompatibilityScoring must be isolated and mockable.
- Ghost elements are scored through the identical path as real items — no special-casing.
- All scoring must be NaN-safe for empty sets.
- See docs/domain/vision-clother-concepts.md for vocabulary.
- Numeric thresholds that are described in `StylistBrain`'s prompt prose AND enforced by scoring math (e.g. formality-mismatch deltas) must live once in `Domain/FashionKnowledgeConstants.swift` and be referenced by both sides — never re-literal the same number in two places. See `docs/decisions/stylist-intelligence-engine.md`.
- `StylistBrain.DecisionHierarchy` tiers are lexicographic, not blended: a lower tier (`.reject`/`.penalize` enforcement) always dominates a higher one; `.guide` tiers (aesthetic trend) may only break ties.
