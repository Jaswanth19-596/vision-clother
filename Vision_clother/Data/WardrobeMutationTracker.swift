//
//  WardrobeMutationTracker.swift
//  Vision_clother
//
//  Cross-feature signal for "the wardrobe changed" — `SwiftDataWardrobeRepository`
//  (`Data/WardrobeRepository.swift`) caches `fetchInventory()`/`fetchFeedbackHistory()`
//  per repository instance (so any long-lived holder, e.g. `DailyAssistantViewModel`,
//  gets it across conversation turns for free), and needs a cheap way to know
//  that cache went stale without a full event-bus/`@Environment`-injected
//  shared object (no such pattern exists yet in this codebase besides
//  `JobQueueStore`, and every item mutation call site — `AddItemViewModel`,
//  `EditItemView`, `ItemDetailView` — already goes through `WardrobeRepository`,
//  so bumping the version there is the single choke point).
//

import Foundation

@MainActor
final class WardrobeMutationTracker {
    static let shared = WardrobeMutationTracker()

    private(set) var version = UUID()

    private init() {}

    func markMutated() {
        version = UUID()
    }
}
