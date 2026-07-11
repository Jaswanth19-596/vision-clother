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
    var onNotificationTapped: (() -> Void)?

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
        let onTapped = onNotificationTapped
        Task { @MainActor in onTapped?() }
        completionHandler()
    }
}
