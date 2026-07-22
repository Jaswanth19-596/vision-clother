//
//  ZoomableImageContainer.swift
//  Vision_clother
//
//  Wraps already-styled image content (an `Image` with whatever
//  `.resizable()/.scaledToFit()` the caller already applied) with
//  pinch-to-zoom, double-tap-to-toggle, and pan-while-zoomed — entirely
//  inside the content's own laid-out bounds, no new full-screen
//  presentation. Reused by every place a generated try-on render is shown
//  full-size: `CombinationDetailView`, `RateCombinationView`,
//  `TryOnResultView`, `ManualPairingView`.
//
//  The pan gesture is attached via `.highPriorityGesture(_:including:)`,
//  toggled between `.subviews` (inert — an ancestor `TabView`/`List` keeps
//  normal swipe/scroll priority) and `.all` (this gesture wins) based on
//  whether the image is currently zoomed past fit. This is what lets a
//  zoomed image live inside `CombinationDetailView`'s paging `TabView`
//  without the page-swipe stealing pan gestures near the image's edges.
//

import SwiftUI

struct ZoomableImageContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var steadyScale: CGFloat = 1
    @GestureState private var pinchDelta: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero
    /// The content's own natural (unscaled) laid-out size, read reactively
    /// via a `background` `GeometryReader` rather than wrapping `content()`
    /// in one directly — a `GeometryReader` as the direct root would greedily
    /// claim all available space from its parent (e.g. unbounded height
    /// inside a `ScrollView`), which would break `content()`'s own
    /// `.scaledToFit()` sizing. `.background` instead is proposed
    /// `content()`'s already-resolved frame, so this measures without
    /// influencing layout.
    @State private var containerSize: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 4
    private let doubleTapScale: CGFloat = 2.5

    private var scale: CGFloat { steadyScale * pinchDelta }
    private var isZoomed: Bool { steadyScale > 1.01 }

    var body: some View {
        content()
            .scaleEffect(scale)
            .offset(
                x: steadyOffset.width + dragDelta.width,
                y: steadyOffset.height + dragDelta.height
            )
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerSize = proxy.size }
                        .onChange(of: proxy.size) { _, newSize in containerSize = newSize }
                }
            }
            .clipped()
            .gesture(magnification(in: containerSize))
            .highPriorityGesture(pan(in: containerSize), including: isZoomed ? .all : .subviews)
            .onTapGesture(count: 2) { toggleZoom(in: containerSize) }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: steadyScale)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: steadyOffset)
    }

    private func magnification(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($pinchDelta) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let newScale = clamp(steadyScale * value, minScale, maxScale)
                steadyScale = newScale
                steadyOffset = clampedOffset(steadyOffset, scale: newScale, in: size)
                logZoomChange()
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let proposed = CGSize(
                    width: steadyOffset.width + value.translation.width,
                    height: steadyOffset.height + value.translation.height
                )
                steadyOffset = clampedOffset(proposed, scale: steadyScale, in: size)
            }
    }

    private func toggleZoom(in size: CGSize) {
        if isZoomed {
            steadyScale = 1
            steadyOffset = .zero
        } else {
            steadyScale = doubleTapScale
            steadyOffset = .zero
        }
        logZoomChange()
    }

    /// Keeps the zoomed image's edges from panning past the container's own
    /// bounds — half the extra width/height the scale adds is the max
    /// offset in either direction.
    private func clampedOffset(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = (size.width * (scale - 1)) / 2
        let maxY = (size.height * (scale - 1)) / 2
        return CGSize(
            width: clamp(offset.width, -maxX, maxX),
            height: clamp(offset.height, -maxY, maxY)
        )
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private func logZoomChange() {
        AppLog.debug(.app, "zoomableImage: scale=\(String(format: "%.2f", steadyScale)) zoomed=\(isZoomed)")
    }
}
