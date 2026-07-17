//
//  AppLog.swift
//  Vision_clother
//
//  Shared diagnostic logger for the whole app — every subsystem below the
//  Domain-layer's `Domain/MLLog.swift` (which stays as-is; it's already
//  narrowly scoped to the AI-Stylist-ML pipeline) routes through here so a
//  future bug report is one consistent, greppable format instead of a mix of
//  ad hoc `os.Logger`s and stray `print()`. Every line goes to both `os.Logger`
//  (Console.app/Xcode, live during development) and `DebugLogStore` (a
//  size-capped file the user can export from Profile → Debug Log with no Mac
//  needed) so the same instrumentation serves both a live debugging session
//  and a bug report pasted back into a future conversation.
//
//  Redaction rule: never log ID tokens, API keys, base64 image payloads, or
//  full LLM prompt/response bodies through this type — log lengths, status
//  codes, ids, and counts instead. Every call site added against this logger
//  must follow that rule.
//

import Foundation
import os

enum AppLog {
    enum Category: String, CaseIterable {
        case auth = "Auth"
        case sync = "Sync"
        case network = "Network"
        case recommendation = "Recommendation"
        case tryOn = "TryOn"
        case vision = "Vision"
        case jobQueue = "JobQueue"
        case viewModel = "ViewModel"
        case payments = "Payments"
        case app = "App"
    }

    /// One `os.Logger` per category, built lazily and cached — same subsystem
    /// `Domain/MLLog.swift` and `Services/PerfLog.swift` already use, so
    /// Console.app filtering by subsystem still catches everything.
    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { category in
            (category, Logger(subsystem: "com.visionclother", category: category.rawValue))
        }
    )

    /// Short, human-scannable id (not a full UUID) for correlating every log
    /// line a single network call produces — client-side request start/end,
    /// and (via the matching `X-Request-Id` header, see
    /// `Services/ProxyAuthHeaders.swift`) the backend's own log line for that
    /// same call.
    static func newRequestID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    static func debug(_ category: Category, _ message: String) {
        emit(category, .debug, message)
    }

    static func info(_ category: Category, _ message: String) {
        emit(category, .info, message)
    }

    /// `notice` (not `.default`) matches `Domain/MLLog.swift`/`Services/PerfLog.swift`'s
    /// existing choice — visible in Console.app without needing debug-level
    /// logging enabled, the level that matters most for a post-hoc bug report.
    static func notice(_ category: Category, _ message: String) {
        emit(category, .default, message)
    }

    static func error(_ category: Category, _ message: String) {
        emit(category, .error, message)
    }

    private static func emit(_ category: Category, _ level: OSLogType, _ message: String) {
        loggers[category]?.log(level: level, "[\(category.rawValue)] \(message)")
        Task {
            await DebugLogStore.shared.append(level: level, category: category.rawValue, message: message)
        }
    }

    /// Brackets `work` with a start/`ok`/`failed` timing log — same shape as
    /// `Services/PerfLog.time`, generalized to any category so Phase 2's
    /// network call sites don't need their own bespoke timer.
    static func time<T>(_ category: Category, _ label: String, _ work: () async throws -> T) async rethrows -> T {
        let start = DispatchTime.now()
        do {
            let result = try await work()
            notice(category, "\(label): \(elapsedMs(since: start))ms ok")
            return result
        } catch {
            self.error(category, "\(label): \(elapsedMs(since: start))ms failed (\(String(describing: error)))")
            throw error
        }
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
