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
            } else {
                uiImage = await ImageStorage.cachedImage(for: assetName)
            }
        }
    }
}
