//
//  RateCombinationView.swift
//  Vision_clother
//
//  Combination Rating: entry point from `CombinationDetailView` ("Rate this
//  outfit"). Swipe + Comment combination feedback (2026-07-27) — a single
//  screen: swipe the outfit's own image love/like/dislike/hate (reusing
//  `SwipeGestureResolver` from
//  `Features/SwipeDiscovery/SwipeDiscoveryViewModel.swift`), add an optional
//  comment on why, then submit. Replaces the previous two-step flow (a
//  dimension-based Level 1/2 form, then a per-item follow-up rating
//  sequence) entirely — see `RateCombinationViewModel.swift`.
//

import SwiftUI
import SwiftData

struct RateCombinationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let combination: SavedCombination
    /// Real items resolved from `combination`'s slot ids — sent (text-only,
    /// no images) to `CombinationChemistryInferenceService` and shown as a
    /// flatlay fallback when there's no rendered image. Snapshotted once via
    /// `@State` in `init` for the same reason the prior implementation did:
    /// `CombinationDetailView`'s `.sheet(item:)` closure re-resolves items on
    /// every one of its own re-renders while this sheet stays open.
    @State private var items: [WardrobeItem]

    init(combination: SavedCombination, items: [WardrobeItem]) {
        self.combination = combination
        self._items = State(initialValue: items)
    }

    @State private var viewModel: RateCombinationViewModel?
    @State private var dragOffset: CGSize = .zero
    @State private var savedTick = 0

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Rate This Outfit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = RateCombinationViewModel(
                outfitID: combination.id,
                items: items,
                repository: SyncingWardrobeRepository(modelContext: modelContext),
                chemistryService: AuthGatedCombinationChemistryInferenceService()
            )
        }
    }

    @ViewBuilder
    private func content(viewModel: RateCombinationViewModel) -> some View {
        Form {
            Section {
                swipeableImage(viewModel: viewModel)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section {
                if let sentiment = viewModel.sentiment {
                    HStack {
                        Image(systemName: sentimentIcon(sentiment))
                            .foregroundStyle(sentiment.liked ? .green : .red)
                        Text(sentimentLabel(sentiment))
                        Spacer()
                        Button("Change") {
                            withAnimation(vcMotion(VCMotion.gesture, reduceMotion: reduceMotion)) {
                                viewModel.sentiment = nil
                                dragOffset = .zero
                            }
                        }
                        .font(.caption)
                    }
                } else {
                    Text("Swipe the outfit right if you liked it, left if you didn't — drag further for a stronger reaction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Why? (Optional)") {
                TextEditor(text: Binding(
                    get: { viewModel.comment },
                    set: { viewModel.comment = $0 }
                ))
                .frame(minHeight: 80)
            }

            if case .failed(let message) = viewModel.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    await viewModel.submit()
                    if viewModel.state == .saved {
                        savedTick += 1
                        dismiss()
                    }
                }
            } label: {
                Text(viewModel.state == .saving ? "Saving\u{2026}" : "Submit")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.state == .saving || viewModel.sentiment == nil)
            .listRowBackground(Color.clear)
        }
        .sensoryFeedback(.success, trigger: savedTick)
    }

    // MARK: - Swipe

    @ViewBuilder
    private func swipeableImage(viewModel: RateCombinationViewModel) -> some View {
        combinationImage
            .offset(dragOffset)
            .rotationEffect(.degrees(Double(dragOffset.width / 20)))
            .overlay(alignment: .topLeading) { swipeStamp(edge: .leading) }
            .overlay(alignment: .topTrailing) { swipeStamp(edge: .trailing) }
            .gesture(dragGesture(viewModel: viewModel))
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func swipeStamp(edge: HorizontalEdge) -> some View {
        let decision = SwipeGestureResolver.decision(forHorizontalTranslation: dragOffset.width)
        let isLeadingStamp = edge == .leading
        let matchesEdge = (isLeadingStamp && (decision == .like || decision == .love))
            || (!isLeadingStamp && (decision == .dislike || decision == .hate))
        if matchesEdge {
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

    /// Settles back to center after a committed swipe (unlike
    /// `SwipeDiscoveryView`'s card stack, there's no next card to fly toward
    /// — the outfit stays on screen while the user optionally adds a
    /// comment, with the sentiment banner above confirming what was
    /// recorded and offering "Change" to re-swipe).
    private func dragGesture(viewModel: RateCombinationViewModel) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let decision = SwipeGestureResolver.decision(forHorizontalTranslation: value.translation.width)
                withAnimation(vcMotion(VCMotion.gesture, reduceMotion: reduceMotion)) {
                    dragOffset = .zero
                }
                if let sentiment = SwipeGestureResolver.sentiment(for: decision) {
                    viewModel.sentiment = sentiment
                }
            }
    }

    private func sentimentIcon(_ sentiment: SwipeSentiment) -> String {
        switch sentiment {
        case .love: return "heart.fill"
        case .like: return "hand.thumbsup.fill"
        case .dislike: return "hand.thumbsdown.fill"
        case .hate: return "xmark.circle.fill"
        }
    }

    private func sentimentLabel(_ sentiment: SwipeSentiment) -> String {
        switch sentiment {
        case .love: return "Loved it"
        case .like: return "Liked it"
        case .dislike: return "Disliked it"
        case .hate: return "Hated it"
        }
    }

    // MARK: - Image

    /// Mirrors `CombinationDetailView.CombinationDetailPage.image`'s pattern
    /// — the saved flatlay render when there is one, falling back to the
    /// per-item flatlay `CombinationDetailPage` also shows full-screen.
    @ViewBuilder
    private var combinationImage: some View {
        if combination.hasRenderedImage {
            CachedWardrobeImage(assetName: combination.imageAssetName) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(VCRadius.shape(VCRadius.card))
            } placeholder: {
                itemFlatlay
            }
        } else {
            itemFlatlay
        }
    }

    private var itemFlatlay: some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                HStack {
                    thumbnail(for: item)

                    VStack(alignment: .leading) {
                        Text(item.slot.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.displayLabel)
                            .font(.subheadline)
                    }

                    Spacer()
                }
            }
        }
        .premiumCard(radius: VCRadius.prominent, material: .regularMaterial)
    }

    @ViewBuilder
    private func thumbnail(for item: WardrobeItem) -> some View {
        CachedWardrobeImage(assetName: item.imageAssetName, thumbnailSize: CGSize(width: 44, height: 44)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(VCRadius.shape(VCRadius.swatch))
        } placeholder: {
            VCRadius.shape(VCRadius.swatch)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
                .frame(width: 44, height: 44)
                .overlay {
                    if item.isGhostElement {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.white)
                    }
                }
        }
    }
}

#Preview {
    let top = WardrobeItem(
        slot: .top,
        formalityScore: 2.5,
        colorProfile: ColorProfile(primaryHex: "#3A7CA5", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer, .springFall],
        fabricWeight: .light
    )
    let bottom = WardrobeItem(
        slot: .bottom,
        formalityScore: 3.0,
        colorProfile: ColorProfile(primaryHex: "#222222", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer, .springFall, .winter],
        fabricWeight: .medium
    )
    let combination = SavedCombination(
        imageAssetName: "preview",
        itemIDsBySlot: [.top: top.id, .bottom: bottom.id],
        labelsBySlot: [.top: top.displayLabel, .bottom: bottom.displayLabel],
        origin: "pairing"
    )
    RateCombinationView(combination: combination, items: [top, bottom])
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}
