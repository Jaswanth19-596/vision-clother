# Models Layer

Shared value and persisted types used by every layer.
- `WardrobeItem`, `FeedbackEvent` are `@Model` classes for SwiftData.
- `GarmentMetadata`, `StyleConstraints`, `OutfitCombination` are plain `Codable` value types.
- All JSON-facing types use explicit `CodingKeys` — no global snake-case decoding strategy.
- Non-standard JSON shapes (e.g. `FormalityRange` as a 2-element array) use custom `Codable` implementations.
- Keep dependency-free — no UIKit, SwiftUI, or service imports.
