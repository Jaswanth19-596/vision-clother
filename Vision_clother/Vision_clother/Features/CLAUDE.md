# Features Layer (Views)

SwiftUI views + `@Observable` view models, one folder per tab/screen.
- Views never call Services directly — always go through a ViewModel.
- All async operations use `async/await` with proper `Task` cancellation.
- Ghost element display is a UI-only concern — use `OutfitCombination.containsGhostElements` / `WardrobeItem.isGhostElement` for badges/labels, never in scoring logic.
- **Feature Folders:** `Closet/`, `Combinations/`, `DailyAssistant/`, `JobQueue/`, `Pairing/`, `Profile/`, `Rating/`, `Root/`, `SwipeDiscovery/`.
- `ManualPairingViewModel.State` is the pattern for multi-step async flows — use explicit state enums, not bare `async throws`.

## Motion

Never write an animation literal in a feature file. Use `.vcAnimation(_:value:)` with a `VCMotion` token (never SwiftUI's `.animation(_:value:)` — `vcAnimation` honors Reduce Motion internally), and a `VCTransition` shape for anything that enters or leaves. Imperative `withAnimation` calls pass their token through `vcMotion(_:reduceMotion:)` using the view's own `@Environment(\.accessibilityReduceMotion)`. Anchor `.vcAnimation` to a container that outlives the change it watches, not to the `Group` whose branches are swapping — and when a state change should animate a branch swap, mutate that state inside `withAnimation`. See `DesignSystem/VCMotion.swift` and the "Motion & the design system" section of `docs/ios/architecture.md`.

## Settings Presentation In List Rows

Any views displaying a `Section` inside a parent `List` must NOT attach presentation modifiers (`.sheet`, `.alert`) or lifecycle modifiers (`.task`) directly to the `Section` or its root body container. Because `List` distributes modifiers attached to structural containers to every generated child row, doing so causes duplicate task evaluations and multiple concurrent presentation attempts, leading to navigation corruption (e.g. sheets automatically dismissing themselves).
Always attach these modifiers to a single, zero-height invisible leaf cell (such as `Color.clear.frame(height: 0)`) nested within the structural section.
