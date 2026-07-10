# Data Layer

Persistence and storage. The only place that touches `ModelContext`.
- `WardrobeRepository` protocol is `@MainActor`-isolated to match `SwiftDataWardrobeRepository`.
- View models take `WardrobeRepository`, never a concrete `ModelContext`.
- `ImageStorage` manages garment photo files on disk — not SwiftData.
- This layer never imports `Domain/` — they are peers, not dependencies.
- See `docs/ios/architecture.md` for the full layer diagram.
