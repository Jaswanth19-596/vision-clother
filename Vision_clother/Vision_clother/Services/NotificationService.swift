//
//  NotificationService.swift
//  Vision_clother
//
//  Local completion notifications for background jobs
//  (`Features/JobQueue/JobQueueStore.swift`). On-device only, no API key gate
//  — same posture as `PhotoLibrarySaver`/`PersonPhotoValidationService`.
//

import Foundation
import UserNotifications

protocol JobNotificationService {
    /// Idempotent — safe to call before every enqueue; only actually prompts
    /// the user once.
    func requestAuthorizationIfNeeded() async
    func notifyUploadSucceeded(itemLabel: String)
    func notifyUploadFailed(reason: String)
    func notifyTryOnSucceeded()
    func notifyTryOnFailed(reason: String)
}

final class UNUserNotificationJobService: JobNotificationService {
    private var hasRequestedAuthorization = false

    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notifyUploadSucceeded(itemLabel: String) {
        post(title: "Item added", body: "\(itemLabel) is in your closet.")
    }

    func notifyUploadFailed(reason: String) {
        post(title: "Upload failed", body: reason)
    }

    func notifyTryOnSucceeded() {
        post(title: "Your try-on is ready", body: "Tap to see how it looks.")
    }

    func notifyTryOnFailed(reason: String) {
        post(title: "Try-on failed", body: reason)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Mock for previews/tests — never touches UNUserNotificationCenter.

struct MockJobNotificationService: JobNotificationService {
    func requestAuthorizationIfNeeded() async {}
    func notifyUploadSucceeded(itemLabel: String) {}
    func notifyUploadFailed(reason: String) {}
    func notifyTryOnSucceeded() {}
    func notifyTryOnFailed(reason: String) {}
}
