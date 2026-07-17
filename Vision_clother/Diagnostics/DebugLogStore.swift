//
//  DebugLogStore.swift
//  Vision_clother
//
//  File-backed mirror of everything `AppLog` emits, so a user can hand over a
//  bug report from Profile → Debug Log (`AccountSectionView`'s "Share Debug
//  Log" action) without a Mac/Xcode session to capture Console.app output.
//  An actor (not a plain class) since `AppLog.emit` fires from arbitrary
//  threads/tasks across every layer of the app — serializing file access
//  here is simpler than making every call site synchronize itself.
//

import Foundation
import os

actor DebugLogStore {
    static let shared = DebugLogStore()

    /// Drop the oldest half of the file once it crosses this size, rather
    /// than growing unbounded — a rare crash-loop shouldn't fill the user's
    /// device storage before they get a chance to export it.
    private static let maxBytes = 5 * 1024 * 1024

    private let fileURL: URL
    private let dateFormatter: DateFormatter

    private init() {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DebugLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("vc-debug.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        dateFormatter = formatter
    }

    func append(level: OSLogType, category: String, message: String) {
        let line = "\(dateFormatter.string(from: Date())) [\(levelLabel(level))] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }

        rotateIfNeeded()
    }

    /// Returns the log file's URL for `ShareLink`/`UIActivityViewController` —
    /// callers read it immediately after, so no snapshot copy is needed.
    func export() -> URL {
        fileURL
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > Self.maxBytes,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? trimmed.data(using: .utf8)?.write(to: fileURL)
    }

    private func levelLabel(_ level: OSLogType) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .error, .fault: return "error"
        default: return "notice"
        }
    }
}
