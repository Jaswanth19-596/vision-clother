//
//  AppNavigator.swift
//  Vision_clother
//
//  App-level navigation state (2026-07-25). Owns the selected tab and a
//  one-shot "show me today's outfit" request so an out-of-tree event — today
//  the Outfit-of-the-Day notification tap (C2) — can both switch to the Daily
//  Assistant tab and ask it to auto-run a "what should I wear today" turn.
//
//  Retained for the app's lifetime (constructed in `Vision_clotherApp`) and
//  injected into the environment, same posture as `UsageTracker`/`JobQueueStore`.
//

import Observation

@MainActor
@Observable
final class AppNavigator {
    enum Tab: Hashable {
        case dailyAssistant, closet, profile, combinations, insights
    }

    var selectedTab: Tab = .dailyAssistant

    /// Set true by the Outfit-of-the-Day notification tap; `DailyAssistantView`
    /// consumes it (sets it back to false) and auto-runs today's outfit turn.
    /// A flag rather than a tick so a cold launch straight from the
    /// notification is still honored once the view first appears.
    var pendingDailyOutfit = false

    /// Drives the first-run onboarding `.fullScreenCover` in `AppRootView`.
    /// Set once at launch by the real-state gate; a set-up user can also
    /// re-present it on demand via `replayOnboarding()` (the Profile DEBUG
    /// "Replay Onboarding" button) without wiping their data.
    var isOnboardingPresented = false

    /// Switch to the Daily Assistant and request today's outfit.
    func requestDailyOutfit() {
        selectedTab = .dailyAssistant
        pendingDailyOutfit = true
    }

    /// Force-show onboarding regardless of the real-state gate — a preview
    /// affordance for an already-set-up account (see `AppRootView`).
    func replayOnboarding() {
        isOnboardingPresented = true
    }
}
