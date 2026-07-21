# Data Layer

Persistence and storage. The only place that touches `ModelContext`.
- `WardrobeRepository` protocol is `@MainActor`-isolated to match `SwiftDataWardrobeRepository`.
- View models take `WardrobeRepository`, never a concrete `ModelContext`.
- `ImageStorage` manages garment photo files on disk — not SwiftData; Cloud Storage is its remote mirror (see below), not a replacement.
- This layer is persistence-focused, but `SwiftDataWardrobeRepository` is a sanctioned exception: `fetchFeedbackHistory()`, `applyImplicitSwipe`, and `recordSwipe` call into `Domain/` (`AttributePreferenceProfile`, `VisualPreferenceProfile`, `VisualClusterUpdater`, `MLLog`) to compute and persist preference-profile aggregates in the same pass as the SwiftData read/write — see `Domain/MLLog.swift`'s doc comment for the rationale. Don't add further Domain/ coupling elsewhere in this layer without discussing it first.
- See `docs/ios/architecture.md` for the full layer diagram.

## Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section)
- `SyncingWardrobeRepository` decorates `WardrobeRepository` for best-effort, outbox-backed Firestore/Storage push — same decorator-over-protocol idiom as `Services/CachedTryOnRenderService.swift`. Construct it, not `SwiftDataWardrobeRepository` directly, at every real call site.
- `SyncMetadata` (`Models/SyncMetadata.swift`) is the local dirty-tracking/outbox table `SyncOutboxWorker` drains — local-only, never synced itself.
- `SyncOutboxWorker.drainNow` chunks eligible dirty rows into groups of up to 500 (Firestore's `WriteBatch` cap) and commits each chunk via `WardrobeSyncService.commitBatch(_:uid:)` — one `WriteBatch` per chunk, not one `setData` per row. A chunk's commit is atomic as a whole; local `SyncMetadata` state (clean vs. bumped `attemptCount`/backoff) is only updated per-row *after* that chunk's commit resolves, so retry/backoff still tracks individually per row even though the network call is batched. See `docs/decisions/resolved-v1.md`'s "Batched Outbox Writes + Bootstrap Push Guard" section.
- `WardrobeSyncCoordinator` owns every account-switch bulk `ModelContext` mutation (bootstrap push/pull, local-mirror wipe) — still within this directory's "only place that touches `ModelContext`" boundary. It holds a *plain* `SwiftDataWardrobeRepository`, never the `Syncing` decorator, to avoid re-marking pulled rows dirty and pushing them right back. Its bootstrap push (`pushEverythingLocal`/`markDirtyForBootstrap`) skips rows whose `SyncMetadata` is already clean, so a partial-bootstrap retry only re-pushes what actually failed, not the entire local dataset.
