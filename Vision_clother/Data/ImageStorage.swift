//
//  ImageStorage.swift
//  Vision_clother
//
//  On-disk persistence for ingested garment photos. `WardrobeItem.imageAssetName`
//  stores the filename this returns, resolved back to a full URL via `url(for:)`
//  whenever a view needs to render it. Kept alongside `WardrobeRepository` —
//  both are persistence boundaries, just for different payload shapes
//  (SwiftData rows vs. image bytes).
//

import CryptoKit
import Foundation

enum ImageStorage {
    /// Short content fingerprint (not a security hash) used to tell "same
    /// image bytes" from "different image bytes" — e.g. correlating
    /// ingestion-pipeline log lines (`JobQueueStore`) and detecting whether a
    /// `SavedCombination`'s base portrait matches the one on disk right now
    /// (`Services/CachedTryOnRenderService.swift`).
    static func fingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("WardrobeImages", isDirectory: true)
    }

    /// Writes `data` under a fresh UUID filename and returns that filename
    /// (not a full URL — `WardrobeItem.imageAssetName` is deliberately
    /// storage-location-agnostic; resolve with `url(for:)` at render time).
    @discardableResult
    static func save(_ data: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).png"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// `nil` if the file is missing (e.g. a Ghost Element's placeholder
    /// filename, which never had bytes written for it).
    static func loadData(for filename: String) -> Data? {
        try? Data(contentsOf: url(for: filename))
    }

    /// Best-effort cleanup — a missing file is not an error worth surfacing.
    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }
}
