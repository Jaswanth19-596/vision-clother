//
//  Vision_clotherApp.swift
//  Vision_clother
//
//  Created by Jaswanth Mada on 7/9/26.
//
//  App entry point. Wires the SwiftData container (CLAUDE.md guardrail #3)
//  and hosts the 3-tab shell (PRD.md §4).
//

import SwiftUI
import SwiftData

@main
struct Vision_clotherApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
        ])
    }
}
