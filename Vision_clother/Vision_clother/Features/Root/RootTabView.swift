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
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    RootTabView()
        .modelContainer(container)
        .environment(JobQueueStore(
            repository: SwiftDataWardrobeRepository(modelContext: container.mainContext),
            backgroundIsolationService: MockBackgroundIsolationService(),
            visionMetadataService: MockVisionMetadataExtractionService(),
            tryOnService: MockTryOnRenderService(),
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService()
        ))
}
