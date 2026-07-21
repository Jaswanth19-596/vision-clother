# Domain Layer

Pure business logic. No UIKit/SwiftUI imports.
- PairCompatibilityScoring must be isolated and mockable.
- Ghost elements are scored through the identical path as real items — no special-casing.
- All scoring must be NaN-safe for empty sets.
- See docs/domain/vision-clother-concepts.md for vocabulary.
- Numeric thresholds that are described in `StylistBrain`'s prompt prose AND enforced by scoring math (e.g. formality-mismatch deltas) must live once in `Domain/FashionKnowledgeConstants.swift` and be referenced by both sides — never re-literal the same number in two places. See `docs/decisions/stylist-intelligence-engine.md`.
- `StylistBrain.DecisionHierarchy` tiers are lexicographic, not blended: a lower tier (`.reject`/`.penalize` enforcement) always dominates a higher one; `.guide` tiers (aesthetic trend) may only break ties.
- Per-slot behavioral differences (required vs. optional, ghost-backed vs. not) belong on `Slot` itself (`isRequired`, `hasGhostDefault` in `Models/WardrobeItem.swift`) — never reintroduce an ad hoc `case .outerwear:`-style special case in engine/validator code when a new slot needs different treatment.
- `StylistBrain.swift` (outfit recommendation prompt) and `StylistQABrain.swift` (wardrobe/Insights Q&A prompt, `Services/StylistQAService.swift`) are deliberately separate prompts for separate LLM calls — never fold Q&A instructions into `StylistBrain`'s Decision Hierarchy prompt or vice versa. See `docs/decisions/resolved-v1.md`'s "Wardrobe/Insights Q&A" section.
