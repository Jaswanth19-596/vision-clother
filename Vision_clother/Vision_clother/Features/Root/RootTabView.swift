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
    /// Drives tab selection so an out-of-tree event (the Outfit-of-the-Day
    /// notification tap) can switch to the Daily Assistant — see `AppNavigator`.
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var jobQueueStore = jobQueueStore
        @Bindable var navigator = navigator

        TabView(selection: $navigator.selectedTab) {
            DailyAssistantView()
                .tabItem { Label("Daily Assistant", systemImage: "sparkles") }
                .tag(AppNavigator.Tab.dailyAssistant)

            ClosetView()
                .tabItem { Label("My Closet", systemImage: "tshirt") }
                .tag(AppNavigator.Tab.closet)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppNavigator.Tab.profile)

            CombinationsView()
                .tabItem { Label("Combinations", systemImage: "square.grid.2x2") }
                .tag(AppNavigator.Tab.combinations)

            InsightsView()
                .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
                .tag(AppNavigator.Tab.insights)
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
        SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self, WornLogEntry.self, SwipeAttributeEvent.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let previewRepository = SyncingWardrobeRepository(modelContext: container.mainContext)
    let previewUsageTracker = UsageTracker(repository: previewRepository, syncService: MockWardrobeSyncService(), entitlementLimitsService: MockEntitlementLimitsService())
    RootTabView()
        .modelContainer(container)
        .environment(AppNavigator())
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
