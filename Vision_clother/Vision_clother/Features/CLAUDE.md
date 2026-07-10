# Features Layer (Views)

SwiftUI views + `@Observable` view models, one folder per tab/screen.
- Views never call Services directly — always go through a ViewModel.
- All async operations use `async/await` with proper `Task` cancellation.
- Ghost element display is a UI-only concern — use `OutfitCombination.containsGhostElements` / `WardrobeItem.isGhostElement` for badges/labels, never in scoring logic.
- Feature folders: `Closet/`, `DailyAssistant/`, `Pairing/`, `Analytics/`, `Root/`.
- `ManualPairingViewModel.State` is the pattern for multi-step async flows — use explicit state enums, not bare `async throws`.
