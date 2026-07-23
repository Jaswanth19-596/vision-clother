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
import ImageIO
import UIKit

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

    /// Decoded-image cache for `CachedWardrobeImage` — grid/detail views were
    /// re-reading and re-decoding the same on-disk PNG from scratch on every
    /// SwiftUI re-render (scroll, selection change, any observed state
    /// mutation), which becomes the dominant cost once a closet/combinations
    /// history grows into the thousands. Bounded so a long session viewing
    /// many distinct photos doesn't retain all of them forever; entries are
    /// invalidated in `write(_:filename:)`/`delete(_:)` so a Cloud Sync
    /// overwrite or removal can never serve stale bytes.
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    /// Cache-first, off-main-actor decode. `[AI-Stylist-ML]` was considered
    /// for this log subsystem but this is pure UI-layer I/O, not ML —
    /// intentionally unlogged per-call to avoid log spam on every grid cell.
    static func cachedImage(for filename: String) async -> UIImage? {
        let key = filename as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(contentsOfFile: url(for: filename).path) else { return nil }
            imageCache.setObject(image, forKey: key)
            return image
        }.value
    }

    /// Per-filename bucket of already-downsampled thumbnails, keyed by pixel
    /// size (e.g. `"168"`) so the same source photo can serve several grid
    /// sizes (Closet 84pt, Combinations 60pt, etc.) without re-decoding. A
    /// plain class (not a struct) so `NSCache` can hold it by reference and
    /// evict it as a unit — bucketing by filename means invalidation below
    /// only needs one `removeObject(forKey:)`, not per-size bookkeeping.
    private final class ThumbnailBucket {
        private let lock = NSLock()
        private var images: [String: UIImage] = [:]

        func image(for sizeKey: String) -> UIImage? {
            lock.lock()
            defer { lock.unlock() }
            return images[sizeKey]
        }

        func setImage(_ image: UIImage, for sizeKey: String) {
            lock.lock()
            defer { lock.unlock() }
            images[sizeKey] = image
        }
    }

    /// Downsampled-thumbnail cache, separate from `imageCache` so requesting
    /// a small grid swatch never promotes a full-resolution decode into
    /// memory, and vice versa. Same bound as `imageCache` — see its doc
    /// comment.
    private static let thumbnailCache: NSCache<NSString, ThumbnailBucket> = {
        let cache = NSCache<NSString, ThumbnailBucket>()
        cache.countLimit = 300
        return cache
    }()

    /// Cache-first, off-main-actor ImageIO downsample — decodes straight to
    /// `maxPixelSize` via `CGImageSourceCreateThumbnailAtIndex` so grid/list
    /// cells (Closet, Combinations, Pairing, etc.) never materialize a
    /// full-resolution bitmap just to render an 80pt swatch. Reserved for
    /// those call sites; detail/zoom views still use `cachedImage(for:)`.
    static func cachedThumbnail(for filename: String, maxPixelSize: CGFloat) async -> UIImage? {
        let key = filename as NSString
        let sizeKey = String(Int(maxPixelSize.rounded()))
        if let cached = thumbnailCache.object(forKey: key)?.image(for: sizeKey) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url(for: filename) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                // These PNGs have no embedded thumbnail, so "Always" (not
                // "IfAbsent") is required to get ImageIO to generate one —
                // it downsamples during decode instead of decoding the full
                // image and then resizing, which is the whole point here.
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let thumbnail = UIImage(cgImage: cgThumbnail)
            let bucket = thumbnailCache.object(forKey: key) ?? ThumbnailBucket()
            bucket.setImage(thumbnail, for: sizeKey)
            thumbnailCache.setObject(bucket, forKey: key)
            return thumbnail
        }.value
    }

    private static func invalidateCache(_ filename: String) {
        imageCache.removeObject(forKey: filename as NSString)
        thumbnailCache.removeObject(forKey: filename as NSString)
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
        invalidateCache(filename)
    }

    /// Explicit-filename write — the Cloud Sync pull path only
    /// (`Data/WardrobeSyncCoordinator.swift`'s background photo prefetch),
    /// writing a photo back under the exact filename its `WardrobeItem`/
    /// `SavedCombination` DTO already references. `save(_:)` keeps minting
    /// fresh UUIDs for the ingestion pipeline — this is the only other writer.
    static func write(_ data: Data, filename: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        invalidateCache(filename)
    }

    /// Removes every locally cached photo — Cloud Sync account-switch wipe
    /// (`Data/WardrobeSyncCoordinator.swift`), since a device with no local
    /// `WardrobeItem`/`SavedCombination` rows for the new account has no use
    /// for the previous account's photo files either.
    static func wipeAll() throws {
        imageCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Cloud-upload-only re-encode: alpha-preserving resize, still PNG —
    /// `WardrobeItem` photos are transparent-background cutouts
    /// (`Services/BackgroundIsolationService.swift`) composited as try-on
    /// reference images, so unlike `downscaledJPEGForUpload` this can't
    /// switch format. The on-device original at `imageAssetName` is never
    /// touched — only the bytes handed to `WardrobeSyncService.uploadImage`
    /// are smaller, to bound Cloud Storage cost/bandwidth at production scale.
    static func downscaledPNGForUpload(_ data: Data, maxDimension: CGFloat = 1024) -> Data {
        guard let image = UIImage(data: data) else { return data }
        return resized(image, maxDimension: maxDimension).pngData() ?? data
    }

    /// Cloud-upload-only re-encode: `SavedCombination` renders are opaque
    /// try-on photos (no alpha channel to preserve), so unlike
    /// `downscaledPNGForUpload` these are safe to re-encode as lossy JPEG for
    /// meaningfully smaller Cloud Storage/bandwidth cost. The on-device
    /// original is never touched.
    static func downscaledJPEGForUpload(_ data: Data, maxDimension: CGFloat = 1024, quality: CGFloat = 0.8) -> Data {
        guard let image = UIImage(data: data) else { return data }
        return resized(image, maxDimension: maxDimension).jpegData(compressionQuality: quality) ?? data
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else { return image }
        let scale = maxDimension / longestSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
