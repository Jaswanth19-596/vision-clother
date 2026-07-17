# Features Layer (Views)

SwiftUI views + `@Observable` view models, one folder per tab/screen.
- Views never call Services directly — always go through a ViewModel.
- All async operations use `async/await` with proper `Task` cancellation.
- Ghost element display is a UI-only concern — use `OutfitCombination.containsGhostElements` / `WardrobeItem.isGhostElement` for badges/labels, never in scoring logic.
- **Feature Folders:** `Closet/`, `Combinations/`, `DailyAssistant/`, `JobQueue/`, `Pairing/`, `Profile/`, `Rating/`, `Root/`, `SwipeDiscovery/`.
- `ManualPairingViewModel.State` is the pattern for multi-step async flows — use explicit state enums, not bare `async throws`.

## Settings Presentation In List Rows

Any views displaying a `Section` inside a parent `List` must NOT attach presentation modifiers (`.sheet`, `.alert`) or lifecycle modifiers (`.task`) directly to the `Section` or its root body container. Because `List` distributes modifiers attached to structural containers to every generated child row, doing so causes duplicate task evaluations and multiple concurrent presentation attempts, leading to navigation corruption (e.g. sheets automatically dismissing themselves).
Always attach these modifiers to a single, zero-height invisible leaf cell (such as `Color.clear.frame(height: 0)`) nested within the structural section.
