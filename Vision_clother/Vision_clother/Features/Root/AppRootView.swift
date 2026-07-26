//
//  AppRootView.swift
//  Vision_clother
//
//  The window's root content: hosts `RootTabView` and gates the first-run
//  `OnboardingFlowView` over it (2026-07-25). The onboarding gate is keyed on
//  *real state*, not just a persisted flag — it shows only when the user is
//  genuinely not set up yet (no base portrait OR an empty closet) and hasn't
//  already dismissed it. So a returning, set-up user — including one whose
//  wardrobe/portrait restored via Cloud Sync on a fresh install — never sees
//  it, and a first-run user is never trapped (every onboarding step is
//  skippable). The gate is evaluated once per launch; completing or skipping
//  sets `hasCompletedOnboarding` so it never re-presents mid-session.
//
//  This sits between the App's `WindowGroup` and `RootTabView` so the
//  onboarding cover (presented from here) inherits the same environment
//  objects the App injects onto this view — `JobQueueStore`/`UsageTracker`/etc.
//  that the reused `AddItemView`/`SwipeDiscoveryView` setup steps depend on.
//

import SwiftData
import SwiftUI

struct AppRootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(AppNavigator.self) private var navigator
    @Query private var allItems: [WardrobeItem]
    @State private var didEvaluate = false

    private var isSetUp: Bool {
        UserPortraitStorage.exists && allItems.contains { !$0.isGhostElement }
    }

    var body: some View {
        @Bindable var navigator = navigator

        RootTabView()
            .task {
                // Evaluate once per launch — the flag flips to true on
                // finish/skip, so this never re-triggers mid-session, and a
                // set-up user is filtered out by `isSetUp` even before the
                // flag exists (e.g. after a reinstall with Cloud Sync).
                guard !didEvaluate else { return }
                didEvaluate = true
                navigator.isOnboardingPresented = !hasCompletedOnboarding && !isSetUp
                // Only nudge users who actually have a closet to style — a
                // daily reminder over an empty wardrobe would be noise.
                // Idempotent, so re-running on a later launch is fine (C2).
                if allItems.contains(where: { !$0.isGhostElement }) {
                    DailyOutfitReminder.schedule()
                }
            }
            // Presentation is driven through `AppNavigator` (not local @State)
            // so the Profile "Replay Onboarding" DEBUG button can re-present it
            // for an already-set-up account.
            .fullScreenCover(isPresented: $navigator.isOnboardingPresented) {
                OnboardingFlowView {
                    hasCompletedOnboarding = true
                    navigator.isOnboardingPresented = false
                }
            }
    }
}
