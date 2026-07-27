# Models Layer

Shared value and persisted types used by every layer.
- `WardrobeItem`, `FeedbackEvent`, `SessionSummary` are `@Model` classes for SwiftData.
- `GarmentMetadata`, `StyleConstraints`, `OutfitCombination` are plain `Codable` value types.
- All JSON-facing types use explicit `CodingKeys` — no global snake-case decoding strategy.
- Non-standard JSON shapes (e.g. `FormalityRange` as a 2-element array) use custom `Codable` implementations.
- Keep dependency-free — no UIKit, SwiftUI, or service imports.
- **`ItemNote` is the one mutable feedback model.** Every other feedback table (`ItemRating`, `OutfitFeedback`, `SwipeAttributeEvent`) is append-only because it feeds a time-decayed aggregate. A note is a current-state claim about a garment that the user edits and deletes in Closet, and nothing decayed reads it — don't "fix" it into an event-sourced table, and don't route defect signal into `AttributePreferenceProfile` (see `docs/domain/vision-clother-concepts.md`'s "a defect is not a preference").
