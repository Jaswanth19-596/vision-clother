# Data Layer

Persistence and storage. The only place that touches `ModelContext`.
- `WardrobeRepository` protocol is `@MainActor`-isolated to match `SwiftDataWardrobeRepository`.
- View models take `WardrobeRepository`, never a concrete `ModelContext`.
- `ImageStorage` manages garment photo files on disk — not SwiftData; Cloud Storage is its remote mirror (see below), not a replacement.
- This layer never imports `Domain/` — they are peers, not dependencies.
- See `docs/ios/architecture.md` for the full layer diagram.

## Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section)
- `SyncingWardrobeRepository` decorates `WardrobeRepository` for best-effort, outbox-backed Firestore/Storage push — same decorator-over-protocol idiom as `Services/CachedTryOnRenderService.swift`. Construct it, not `SwiftDataWardrobeRepository` directly, at every real call site.
- `SyncMetadata` (`Models/SyncMetadata.swift`) is the local dirty-tracking/outbox table `SyncOutboxWorker` drains — local-only, never synced itself.
- `WardrobeSyncCoordinator` owns every account-switch bulk `ModelContext` mutation (bootstrap push/pull, local-mirror wipe) — still within this directory's "only place that touches `ModelContext`" boundary. It holds a *plain* `SwiftDataWardrobeRepository`, never the `Syncing` decorator, to avoid re-marking pulled rows dirty and pushing them right back.
