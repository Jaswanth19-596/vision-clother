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

import SwiftData
import SwiftUI
import UserNotifications

@main
struct Vision_clotherApp: App {
    private let modelContainer: ModelContainer
    private let jobQueueStore: JobQueueStore
    private let notificationDelegate = NotificationDelegate()

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Schema(SchemaV3.models),
                migrationPlan: SavedCombinationMigrationPlan.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContainer = container

        let repository = SwiftDataWardrobeRepository(modelContext: container.mainContext)
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
        }
        .modelContainer(modelContainer)
    }
}
