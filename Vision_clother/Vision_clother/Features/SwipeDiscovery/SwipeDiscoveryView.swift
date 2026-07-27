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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `.sensoryFeedback(_:trigger:)` triggers for the moderate (Like/Dislike)
    /// and strongest (Love/Hate) sentiment commits — two separate counters
    /// since the two intensities map to different haptic weights.
    @State private var moderateImpactTick = 0
    @State private var intenseImpactTick = 0

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
                repository: SyncingWardrobeRepository(modelContext: modelContext),
                feedService: ServiceFactory.makeStockImageFeedService(),
                visionService: ServiceFactory.makeVisionMetadataExtractionService()
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

            controls(viewModel: viewModel)
        }
        .padding(VCSpacing.lg)
        .sensoryFeedback(.impact(weight: .light), trigger: moderateImpactTick)
        .sensoryFeedback(.impact(weight: .heavy), trigger: intenseImpactTick)
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
        let isLeadingStamp = edge == .leading
        let matchesEdge = (isLeadingStamp && (decision == .like || decision == .love))
            || (!isLeadingStamp && (decision == .dislike || decision == .hate))
        if matchesEdge {
            // Love/Hate get a visibly bigger stamp than the moderate Like/
            // Dislike, so the drag's intensity is legible before release.
            let isIntense = decision == .love || decision == .hate
            let label = isLeadingStamp ? (decision == .love ? "LOVE" : "LIKE") : (decision == .hate ? "HATE" : "NOPE")
            let tint: Color = isLeadingStamp ? .green : .red
            Text(label)
                .font(isIntense ? .largeTitle.bold() : .title2.bold())
                .foregroundStyle(tint)
                .padding(.horizontal, VCSpacing.md)
                .padding(.vertical, VCSpacing.xs)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint, lineWidth: isIntense ? 5 : 3)
                )
                .rotationEffect(.degrees(isLeadingStamp ? -15 : 15))
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
                let decision = SwipeGestureResolver.decision(forHorizontalTranslation: value.translation.width)
                if let sentiment = SwipeGestureResolver.sentiment(for: decision) {
                    commitSwipe(sentiment: sentiment, viewModel: viewModel)
                } else {
                    withAnimation(vcMotion(VCMotion.gesture, reduceMotion: reduceMotion)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    /// Plays the fly-off-screen animation to completion before mutating the
    /// view model's deck — swapping in the next card mid-flight would cut
    /// the animation short and read as a jump-cut.
    private func commitSwipe(sentiment: SwipeSentiment, viewModel: SwipeDiscoveryViewModel) {
        guard viewModel.topPhoto != nil else { return }
        withAnimation(vcMotion(VCMotion.commit, reduceMotion: reduceMotion)) {
            dragOffset = CGSize(width: sentiment.liked ? 600 : -600, height: dragOffset.height)
        }
        switch sentiment {
        case .love, .hate:
            intenseImpactTick += 1
        case .like, .dislike:
            moderateImpactTick += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + VCMotion.commitDuration) {
            viewModel.swipe(sentiment: sentiment)
            dragOffset = .zero
        }
    }

    // MARK: - Controls

    /// Explicit 4-button fallback — same swipe outcomes as the drag gesture's
    /// two thresholds, for accessibility and testability.
    private func controls(viewModel: SwipeDiscoveryViewModel) -> some View {
        HStack(spacing: VCSpacing.xl) {
            sentimentButton(sentiment: .hate, systemImage: "heart.slash.fill", tint: .red, viewModel: viewModel)
            sentimentButton(sentiment: .dislike, systemImage: "xmark", tint: .red, viewModel: viewModel)
            sentimentButton(sentiment: .like, systemImage: "heart", tint: .green, viewModel: viewModel)
            sentimentButton(sentiment: .love, systemImage: "heart.fill", tint: .green, viewModel: viewModel)
        }
    }

    private func sentimentButton(
        sentiment: SwipeSentiment, systemImage: String, tint: Color, viewModel: SwipeDiscoveryViewModel
    ) -> some View {
        let isIntense = sentiment == .love || sentiment == .hate
        return Button {
            commitSwipe(sentiment: sentiment, viewModel: viewModel)
        } label: {
            Image(systemName: systemImage)
                .font(isIntense ? .title.weight(.semibold) : .title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: isIntense ? 56 : 48, height: isIntense ? 56 : 48)
                .background(.thinMaterial, in: Circle())
        }
        .disabled(viewModel.topPhoto == nil)
        .accessibilityLabel(sentimentAccessibilityLabel(sentiment))
    }

    private func sentimentAccessibilityLabel(_ sentiment: SwipeSentiment) -> String {
        switch sentiment {
        case .love: return "Love"
        case .like: return "Like"
        case .dislike: return "Dislike"
        case .hate: return "Hate"
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
            SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self, SwipeAttributeEvent.self,
            SwipeCombinationEvent.self,
        ],
        inMemory: true
    )
}
