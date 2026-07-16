//
//  SwipeDiscoveryView.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste: a Tinder-style card stack over the Pexels
//  photo deck (`Services/StockImageFeedService.swift`). Entry point is a
//  link from `Features/Profile/ProfileView.swift`. Follows `ProfileView`'s
//  lazy `@State` view-model-in-`.task` construction convention
//  (Features/CLAUDE.md).
//

import SwiftData
import SwiftUI

struct SwipeDiscoveryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: SwipeDiscoveryViewModel?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Discover Your Style")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            let vm = SwipeDiscoveryViewModel(
                repository: SwiftDataWardrobeRepository(modelContext: modelContext),
                feedService: ServiceFactory.makeStockImageFeedService(),
                embeddingService: ServiceFactory.makeImageEmbeddingService()
            )
            viewModel = vm
            await vm.loadDeckIfNeeded()
        }
    }

    @ViewBuilder
    private func content(viewModel: SwipeDiscoveryViewModel) -> some View {
        VStack(spacing: VCSpacing.lg) {
            CalibrationProgressBadge(progress: viewModel.calibrationProgress, isTrained: viewModel.isTrained)
                .padding(.horizontal, VCSpacing.lg)

            Text("Like or dislike a few looks — we'll use it to fine-tune your recommendations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VCSpacing.lg)

            if let lastSwipeError = viewModel.lastSwipeError {
                Text(lastSwipeError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            cardStack(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    DriftFeedbackPill(amount: viewModel.lastDriftAmount, isVisible: viewModel.showDriftFeedback)
                        .padding(.top, VCSpacing.sm)
                }

            controls(viewModel: viewModel)
        }
        .padding(VCSpacing.lg)
    }

    // MARK: - Card stack

    @ViewBuilder
    private func cardStack(viewModel: SwipeDiscoveryViewModel) -> some View {
        let stack = viewModel.visibleStack
        if stack.isEmpty {
            emptyOrLoadingState(viewModel: viewModel)
        } else {
            GeometryReader { proxy in
                ZStack {
                    ForEach(Array(stack.enumerated()), id: \.element.id) { index, photo in
                        cardView(photo, size: proxy.size)
                            .zIndex(Double(stack.count - index))
                            .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.04)
                            .offset(y: index == 0 ? 0 : CGFloat(index) * 8)
                            .offset(index == 0 ? dragOffset : .zero)
                            .rotationEffect(index == 0 ? .degrees(Double(dragOffset.width / 20)) : .zero)
                            .allowsHitTesting(index == 0)
                            .gesture(dragGesture(viewModel: viewModel))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private func emptyOrLoadingState(viewModel: SwipeDiscoveryViewModel) -> some View {
        VStack(spacing: VCSpacing.md) {
            if viewModel.loadState == .loading {
                ProgressView("Finding photos…")
            } else if case .failed(let message) = viewModel.loadState {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("You're all caught up — check back later for more.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(VCSpacing.xl)
    }

    private func cardView(_ photo: StockPhoto, size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            AsyncImage(url: URL(string: photo.imageURLString)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color.secondary.opacity(0.15)
                        .overlay(Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary))
                default:
                    Color.secondary.opacity(0.1)
                        .overlay(ProgressView())
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()

            HStack {
                Text(photo.attributionText)
                    .font(.caption2)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(VCSpacing.sm)
            .background(.black.opacity(0.35))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(VCRadius.shape(VCRadius.prominent))
        .overlay(alignment: .topLeading) { swipeStamp(edge: .leading) }
        .overlay(alignment: .topTrailing) { swipeStamp(edge: .trailing) }
        .vcShadow()
    }

    @ViewBuilder
    private func swipeStamp(edge: HorizontalEdge) -> some View {
        let decision = SwipeGestureResolver.decision(forHorizontalTranslation: dragOffset.width)
        let isLikeStamp = edge == .leading
        if (isLikeStamp && decision == .like) || (!isLikeStamp && decision == .dislike) {
            Text(isLikeStamp ? "LIKE" : "NOPE")
                .font(.title2.bold())
                .foregroundStyle(isLikeStamp ? .green : .red)
                .padding(.horizontal, VCSpacing.md)
                .padding(.vertical, VCSpacing.xs)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isLikeStamp ? .green : .red, lineWidth: 3)
                )
                .rotationEffect(.degrees(isLikeStamp ? -15 : 15))
                .padding(VCSpacing.lg)
        }
    }

    // MARK: - Gesture

    private func dragGesture(viewModel: SwipeDiscoveryViewModel) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                switch SwipeGestureResolver.decision(forHorizontalTranslation: value.translation.width) {
                case .like:
                    commitSwipe(liked: true, viewModel: viewModel)
                case .dislike:
                    commitSwipe(liked: false, viewModel: viewModel)
                case .undecided:
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    /// Plays the fly-off-screen animation to completion before mutating the
    /// view model's deck — swapping in the next card mid-flight would cut
    /// the animation short and read as a jump-cut.
    private func commitSwipe(liked: Bool, viewModel: SwipeDiscoveryViewModel) {
        guard viewModel.topPhoto != nil else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: liked ? 600 : -600, height: dragOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            viewModel.swipe(liked: liked)
            dragOffset = .zero
        }
    }

    // MARK: - Controls

    /// Explicit buttons as a non-gesture fallback — same swipe outcome as
    /// the drag gesture, for accessibility and testability.
    private func controls(viewModel: SwipeDiscoveryViewModel) -> some View {
        HStack(spacing: VCSpacing.xxl) {
            Button {
                commitSwipe(liked: false, viewModel: viewModel)
            } label: {
                Image(systemName: "xmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 56, height: 56)
                    .background(.thinMaterial, in: Circle())
            }
            .disabled(viewModel.topPhoto == nil)
            .accessibilityLabel("Dislike")

            Button {
                commitSwipe(liked: true, viewModel: viewModel)
            } label: {
                Image(systemName: "heart.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 56, height: 56)
                    .background(.thinMaterial, in: Circle())
            }
            .disabled(viewModel.topPhoto == nil)
            .accessibilityLabel("Like")
        }
    }
}

#Preview {
    NavigationStack {
        SwipeDiscoveryView()
    }
    .modelContainer(
        for: [
            WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self,
            SavedCombination.self, ItemRating.self, UserStyleProfile.self,
            SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self,
        ],
        inMemory: true
    )
}
