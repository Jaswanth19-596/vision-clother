//
//  Vision_clotherApp.swift
//  Vision_clother
//
//  Created by Jaswanth Mada on 7/9/26.
//
//  App entry point. Wires the SwiftData container (CLAUDE.md guardrail #3),
//  the app-wide background job queue (`Features/JobQueue/JobQueueStore.swift`
//  — the first piece of app-root-level shared state in this codebase), and
//  hosts the 4-tab shell (PRD.md §4). An explicit `ModelContainer` (rather
//  than the `.modelContainer(for:)` scene-modifier sugar) is required here so
//  `JobQueueStore` can be handed the exact same `ModelContext` every view's
//  `@Environment(\.modelContext)` resolves to — otherwise a background job's
//  writes wouldn't appear in the live `@Query`-backed views.
//

import FirebaseAuth
import GoogleSignIn
import SwiftData
import SwiftUI
import UserNotifications

@main
struct Vision_clotherApp: App {
    private let modelContainer: ModelContainer
    private let jobQueueStore: JobQueueStore
    /// Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section) —
    /// retained for the app's lifetime so its `AuthService.shared.$uid`
    /// Combine subscription (`Data/WardrobeSyncCoordinator.swift`) stays
    /// alive; a locally-scoped instance would be deallocated immediately.
    private let syncCoordinator: WardrobeSyncCoordinator
    private let notificationDelegate = NotificationDelegate()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must run before any Firebase Auth call — see
        // Config/FirebaseBootstrap.swift.
        FirebaseBootstrap.configure()

        let schema = Schema(SchemaV9.models)
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: SavedCombinationMigrationPlan.self
            )
        } catch {
            container = Self.recreatingContainerAfterStoreReset(schema: schema, originalError: error)
        }
        modelContainer = container

        let repository = SyncingWardrobeRepository(modelContext: container.mainContext)
        syncCoordinator = WardrobeSyncCoordinator(modelContext: container.mainContext, syncService: ServiceFactory.makeWardrobeSyncService())
        let store = JobQueueStore(
            repository: repository,
            backgroundIsolationService: ServiceFactory.makeBackgroundIsolationService(),
            imagePreprocessingService: ServiceFactory.makeImagePreprocessingService(),
            visionMetadataService: ServiceFactory.makeVisionMetadataExtractionService(),
            tryOnService: ServiceFactory.makeTryOnRenderService(repository: repository),
            photoLibrarySaver: ServiceFactory.makePhotoLibrarySaver(),
            notificationService: ServiceFactory.makeNotificationService()
        )
        jobQueueStore = store

        // Tapping a job-completion notification opens the Activity panel —
        // not a deep link to the specific item/render, to keep this bounded.
        UNUserNotificationCenter.current().delegate = notificationDelegate
        notificationDelegate.onNotificationTapped = { [store] in
            store.isPanelPresented = true
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(jobQueueStore)
                // Routes both the Google Sign-In consent redirect and the
                // phone-auth reCAPTCHA verification redirect back into the
                // app — see Vision_clother/Config/URLSchemes.plist and
                // Services/AuthService.swift.
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    _ = Auth.auth().canHandle(url)
                }
                // Cloud Sync foreground safety net — a bounded delta
                // reconcile, not a full pull, catching anything missed by
                // the best-effort per-mutation push (e.g. offline at the
                // time). See Data/WardrobeSyncCoordinator.swift.
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await syncCoordinator.reconcileIfSignedIn() }
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    /// Last-resort recovery for a `ModelContainer` init failure that no
    /// schema-migration-plan edit can fix — e.g. a store whose on-disk
    /// version/checksum metadata was stamped mid-iteration (a live `@Model`
    /// type's shape changed while its `VersionedSchema` still claimed an
    /// already-shipped version number) and now matches no known stage,
    /// surfacing as SwiftData's "unknown model version" error. That
    /// provenance is corrupt, not recoverable, so the only way forward is a
    /// fresh store; this trades a hard app-breaking crash for a local-data
    /// reset in that one failure path. Any other, non-store cause (e.g. a
    /// genuinely malformed schema) still fails the same way after retrying,
    /// which fatalErrors below with both errors for context.
    private static func recreatingContainerAfterStoreReset(schema: Schema, originalError: Error) -> ModelContainer {
        let storeURL = ModelConfiguration().url
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fileManager.removeItem(atPath: storeURL.path + suffix)
        }
        do {
            return try ModelContainer(for: schema, migrationPlan: SavedCombinationMigrationPlan.self)
        } catch {
            fatalError("Failed to create ModelContainer even after resetting the store. Original error: \(originalError). Retry error: \(error)")
        }
    }
}
