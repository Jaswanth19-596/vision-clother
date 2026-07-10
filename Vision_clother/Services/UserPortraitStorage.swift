//
//  UserPortraitStorage.swift
//  Vision_clother
//
//  On-disk persistence for the user's own full-body photo (Manual Outfit
//  Pairing's try-on base image). Deliberately not a SwiftData model — there
//  is exactly one of these per user, so its presence on disk *is* the state;
//  a database row would just duplicate that. Mirrors Data/ImageStorage.swift's
//  Documents-directory pattern, but with one fixed filename instead of a
//  UUID per item, since re-uploading replaces the single portrait rather
//  than adding another one.
//

import Foundation

enum UserPortraitStorage {
    private static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("UserPortrait", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("base_portrait.jpg")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Overwrites any previously saved portrait — there is only ever one.
    static func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    /// Best-effort cleanup, matching ImageStorage.delete's posture — a
    /// missing file is not an error worth surfacing.
    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
