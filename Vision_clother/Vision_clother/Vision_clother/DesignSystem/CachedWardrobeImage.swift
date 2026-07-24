//
//  CachedWardrobeImage.swift
//  Vision_clother
//
//  Every photo-bearing cell (Closet grid, item/combination detail, rating
//  flows, outfit cards) used to call `UIImage(contentsOfFile:)` directly
//  inside a `@ViewBuilder` computed property — a synchronous disk read +
//  decode on the main actor, re-run on every re-render with no caching.
//  Fine at a handful of items; the dominant source of scroll/animation
//  jank once a closet/history grows into the thousands. This routes every
//  call site through `ImageStorage.cachedImage(for:)`'s decoded-image cache
//  and off-main-actor decode instead.
//

import SwiftUI
import UIKit

struct CachedWardrobeImage<ImageContent: View, Placeholder: View>: View {
    let assetName: String?
    /// Point size of the on-screen swatch, e.g. `CGSize(width: 84, height:
    /// 84)` — set this for every grid/list cell so it decodes a downsampled
    /// thumbnail instead of the full-resolution photo. Leave `nil` (default)
    /// for detail/zoom views that need the real resolution.
    var thumbnailSize: CGSize? = nil
    @ViewBuilder var imageContent: (Image) -> ImageContent
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    /// Optional, not `WardrobeSyncCoordinator.self` non-optional like
    /// `ClosetView` — a missing environment value (e.g. a preview context)
    /// must degrade the same way a missing network path does: show
    /// whatever's already on disk, never crash.
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator: WardrobeSyncCoordinator?
    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                imageContent(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: assetName) {
            guard let assetName else {
                uiImage = nil
                return
            }
            if let thumbnailSize {
                let maxPixelSize = max(thumbnailSize.width, thumbnailSize.height) * displayScale
                uiImage = await ImageStorage.cachedThumbnail(for: assetName, maxPixelSize: maxPixelSize)
                return
            }
            // Detail path: show whatever's already on disk immediately —
            // full-res if present, else a thumbnail-quality bitmap, never a
            // blank placeholder while a fetch is pending.
            uiImage = await ImageStorage.cachedImage(for: assetName)
            if uiImage == nil {
                uiImage = await ImageStorage.cachedThumbnail(for: assetName, maxPixelSize: 1024 * displayScale)
            }
            guard !ImageStorage.hasFullResolution(for: assetName) else { return }
            await syncCoordinator?.ensureFullResolution(filename: assetName)
            if ImageStorage.hasFullResolution(for: assetName) {
                uiImage = await ImageStorage.cachedImage(for: assetName)
            }
        }
    }
}
