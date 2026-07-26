//
//  DailyOutfitReminder.swift
//  Vision_clother
//
//  "Outfit of the Day" daily local notification (2026-07-25, C2). Makes the
//  Daily Assistant actually daily: a repeating morning reminder whose tap
//  deep-links into the Daily Assistant and auto-runs a "what should I wear
//  today" turn (routed via `NotificationDelegate` → `AppNavigator`). On-device
//  only, no API key gate — same posture as `NotificationService.swift`.
//
//  Scheduling is idempotent (fixed identifier, replace-then-add) and gated by
//  the caller on the user actually having a closet — a reminder to style an
//  empty wardrobe would be noise (see `AppRootView`).
//

import UserNotifications

enum DailyOutfitReminder {
    /// Stable id so re-scheduling on every launch replaces rather than stacks.
    static let identifier = "daily-outfit-reminder"
    /// Lets `NotificationDelegate` distinguish this from job-completion
    /// notifications and route the tap to `AppNavigator.requestDailyOutfit()`.
    static let categoryIdentifier = "DAILY_OUTFIT"
    /// Local hour to fire (24h).
    private static let hour = 8

    /// Requests notification permission if still undetermined, then (re)schedules
    /// the repeating morning reminder. Safe to call on every launch. Silently
    /// no-ops if the user has denied notifications.
    static func schedule() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            let refreshed = await center.notificationSettings()
            guard refreshed.authorizationStatus == .authorized
                || refreshed.authorizationStatus == .provisional else { return }

            var when = DateComponents()
            when.hour = hour
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)

            let content = UNMutableNotificationContent()
            content.title = "Your outfit for today ☀️"
            content.body = "Tap to see what to wear — styled from your closet and today's weather."
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            try? await center.add(request)
        }
    }
}
