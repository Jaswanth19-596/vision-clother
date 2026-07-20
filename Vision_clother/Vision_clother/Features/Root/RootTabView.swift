//
//  RootTabView.swift
//  Vision_clother
//
//  The 4-tab layout from PRD.md §4 (Combinations added post-V1 to make
//  saved try-on images browsable — see Features/Combinations/CLAUDE.md-level
//  notes in CombinationsView.swift).
//

import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(JobQueueStore.self) private var jobQueueStore

    var body: some View {
        @Bindable var jobQueueStore = jobQueueStore

        TabView {
            DailyAssistantView()
                .tabItem { Label("Daily Assistant", systemImage: "sparkles") }

            ClosetView()
                .tabItem { Label("My Closet", systemImage: "tshirt") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }

            CombinationsView()
                .tabItem { Label("Combinations", systemImage: "square.grid.2x2") }

            InsightsView()
                .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
        }
        // Single source of truth for the Activity panel — hosted once here
        // (rather than per-tab) so a notification tap can open it regardless
        // of which tab is active (`Vision_clotherApp`'s `NotificationDelegate`
        // flips `jobQueueStore.isPanelPresented`).
        .sheet(isPresented: $jobQueueStore.isPanelPresented) {
            JobQueuePanelView()
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self, UserStyleProfile.self,
        SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let previewRepository = SyncingWardrobeRepository(modelContext: container.mainContext)
    let previewUsageTracker = UsageTracker(repository: previewRepository, syncService: MockWardrobeSyncService(), entitlementLimitsService: MockEntitlementLimitsService())
    RootTabView()
        .modelContainer(container)
        .environment(JobQueueStore(
            repository: previewRepository,
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: MockVisionMetadataExtractionService(),
            tryOnService: MockTryOnRenderService(),
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService(),
            usageTracker: previewUsageTracker
        ))
        .environment(WardrobeSyncCoordinator(modelContext: container.mainContext, syncService: MockWardrobeSyncService()))
        .environment(previewUsageTracker)
}
