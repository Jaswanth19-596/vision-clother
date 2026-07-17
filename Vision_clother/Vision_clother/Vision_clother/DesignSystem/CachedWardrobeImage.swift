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
    @ViewBuilder var imageContent: (Image) -> ImageContent
    @ViewBuilder var placeholder: () -> Placeholder

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
            uiImage = await ImageStorage.cachedImage(for: assetName)
        }
    }
}
