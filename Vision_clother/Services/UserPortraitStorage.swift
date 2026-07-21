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

    /// Bundled stand-in body photo (`Resources/DefaultBodyPhoto.jpg`) offered
    /// in Profile as an alternative to the user's own photo, for anyone who'd
    /// rather not upload a personal photo. Identical bytes on every install,
    /// so `isDefaultBodyPhoto(_:)` can tell "the user picked this" from "the
    /// user has their own photo" by plain equality — no extra persisted flag,
    /// and it rides the exact same save/upload path a real photo does, so
    /// Cloud Sync carries the choice across devices for free.
    static let defaultBodyPhotoData: Data? = {
        guard let url = Bundle.main.url(forResource: "DefaultBodyPhoto", withExtension: "jpg") else { return nil }
        return try? Data(contentsOf: url)
    }()

    static func isDefaultBodyPhoto(_ data: Data) -> Bool {
        data == defaultBodyPhotoData
    }
}
