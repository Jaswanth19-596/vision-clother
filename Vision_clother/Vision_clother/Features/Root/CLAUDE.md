# Features/Root Module

Root container views and application navigation bootstrap.
- `RootTabView` orchestrates the main navigation tabs: Closet, Pairing, Daily Assistant, Profile.
- Houses the shared environment setups for `WardrobeSyncCoordinator`, `StoreKitPaymentManager`, `UsageTracker`, and SwiftData container dependencies.
- Embeds background upload and try-on progress tracking badges on tabs via the `JobQueueBadgeButton`.
