//
//  NotificationDelegate.swift
//  Vision_clother
//
//  Makes job-completion notifications (`NotificationService.swift`) present
//  even while the app is foregrounded, and routes a tap back into the app.
//  Set as `UNUserNotificationCenter.current().delegate` in
//  `Vision_clotherApp.init()`.
//

import UserNotifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Tap on a job-completion notification (upload/try-on) — opens the
    /// Activity panel.
    var onNotificationTapped: (() -> Void)?
    /// Tap on the daily Outfit-of-the-Day reminder — routes to the Daily
    /// Assistant and auto-runs today's outfit (see `DailyOutfitReminder`).
    var onDailyOutfitTapped: (() -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let isDailyOutfit = request.identifier == DailyOutfitReminder.identifier
            || request.content.categoryIdentifier == DailyOutfitReminder.categoryIdentifier
        let onJobTapped = onNotificationTapped
        let onDaily = onDailyOutfitTapped
        Task { @MainActor in
            if isDailyOutfit { onDaily?() } else { onJobTapped?() }
        }
        completionHandler()
    }
}
