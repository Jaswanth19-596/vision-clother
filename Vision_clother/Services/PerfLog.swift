//
//  PerfLog.swift
//  Vision_clother
//
//  Temporary diagnostic instrumentation for the Daily Assistant "Get Outfit
//  Ideas" latency investigation — brackets each step/substep of
//  DailyAssistantViewModel.resolveOutfits with a start/stop timing log so the
//  slow step(s) can be identified from a real run before any fix is applied.
//

import Foundation
import os

enum PerfLog {
    static let logger = Logger(subsystem: "com.visionclother", category: "Perf")

    /// Brackets `work` with a start/stop timing log, on both success and
    /// failure, so a slow attempt that ultimately throws still shows up with
    /// its elapsed time instead of vanishing silently.
    static func time<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let start = DispatchTime.now()
        do {
            let result = try await work()
            logger.notice("[perf] \(label): \(Self.elapsedMs(since: start))ms ok")
            return result
        } catch {
            logger.notice("[perf] \(label): \(Self.elapsedMs(since: start))ms failed (\(String(describing: error)))")
            throw error
        }
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
