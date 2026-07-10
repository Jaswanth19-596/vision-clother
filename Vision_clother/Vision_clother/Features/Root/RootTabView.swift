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
    var body: some View {
        TabView {
            DailyAssistantView()
                .tabItem { Label("Daily Assistant", systemImage: "sparkles") }

            ClosetView()
                .tabItem { Label("My Closet", systemImage: "tshirt") }

            AnalyticsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar") }

            CombinationsView()
                .tabItem { Label("Combinations", systemImage: "square.grid.2x2") }
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self],
            inMemory: true
        )
}
