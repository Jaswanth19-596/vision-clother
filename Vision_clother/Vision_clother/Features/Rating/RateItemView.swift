//
//  RateItemView.swift
//  Vision_clother
//
//  Item Rating & Preference Learning. Single-scroll rating form — Level 1
//  (Fit, Comfort, Confidence, Wear again?) plus Level 2 Fashion Evaluation
//  (Versatility, Predicted Wear Frequency, Style Identity, Quality
//  Perception) — reusing `AddItemView`'s Form/Section idiom.
//  `RateItemQuestionsView` is the shared question body, used exclusively by
//  `RateCombinationView`'s per-item step — rating only happens from the
//  Combinations tab (`CombinationDetailView` → `RateCombinationView`).
//

import SwiftUI
import SwiftData

/// The Level 1 (Fit/Comfort/Confidence/Wear again) + Level 2 Fashion
/// Evaluation (Versatility/Predicted Wear Frequency/Style Identity/Quality
/// Perception) form used by `RateCombinationView`'s per-item step — generic
/// over `RatingQuestionsViewModel`. Shows `item`'s photo (or color-swatch
/// fallback) at the top so the user can see exactly what they're rating,
/// matching `ItemDetailView.garmentPreview`'s pattern.
struct RateItemQuestionsView<ViewModel: RatingQuestionsViewModel>: View {
    let item: WardrobeItem
    @Bindable var viewModel: ViewModel
    let submitLabel: String
    let onSaved: () -> Void

    /// Ticks once on a completed save — drives the submit-rating
    /// critical-action haptic.
    @State private var savedTick = 0

    var body: some View {
        Form {
            Section {
                itemPreview
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Fit") {
                Picker("Fit", selection: $viewModel.fit) {
                    ForEach(FitRating.allCases) { fit in
                        Text(shortLabel(for: fit)).tag(fit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(viewModel.fit.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Section("Comfort") {
                Text("How did the fabric feel?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.comfort)
            }

            Section("Confidence") {
                Text("How did you feel wearing it?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ConfidenceEmojiRow(rating: $viewModel.confidence)
            }

            Section("Wear again?") {
                WearAgainRow(wearAgain: $viewModel.wearAgain)
            }

            Section("Versatility") {
                Text("How versatile is this piece?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.versatility)
            }

            Section("Predicted Wear Frequency") {
                Text("How often do you see yourself wearing this?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.frequency)
            }

            Section("Style Identity") {
                Text("Does this feel like \u{201C}you\u{201D}?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.styleIdentity)
            }

            Section("Quality Perception") {
                Text("How would you rate the quality of this piece?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.qualityPerception)
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
                        onSaved()
                    }
                }
            } label: {
                Text(viewModel.state == .saving ? "Saving…" : submitLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.state == .saving)
            .listRowBackground(Color.clear)
        }
        .sensoryFeedback(.success, trigger: savedTick)
    }

    private func shortLabel(for fit: FitRating) -> String {
        switch fit {
        case .tooTight: return "Tight"
        case .slightlyTight: return "Snug"
        case .justRight: return "Right"
        case .slightlyLoose: return "Loose"
        case .tooLoose: return "Baggy"
        }
    }

    /// Mirrors `ItemDetailView.garmentPreview(for:)` — photo via
    /// `ImageStorage` when the item has one, else a `colorProfile`-tinted
    /// swatch with a ghost/tshirt fallback overlay.
    @ViewBuilder
    private var itemPreview: some View {
        if let imageAssetName = item.imageAssetName,
           let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
        } else {
            VCRadius.shape(VCRadius.card)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
                .frame(height: 200)
                .overlay {
                    if item.isGhostElement {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.largeTitle)
                            Text("Starter Piece")
                                .font(.caption)
                        }
                        .foregroundStyle(.white)
                    } else {
                        Image(systemName: "tshirt.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
        }
    }
}

// MARK: - Question controls

/// Internal (not `private`) — reused by `RateCombinationView.swift`'s
/// dimension-based outfit rating form.
struct StarRatingRow: View {
    @Binding var rating: Int

    var body: some View {
        HStack {
            Spacer()
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating ? "star.fill" : "star")
                    .foregroundStyle(value <= rating ? .yellow : .secondary)
                    .font(.title2)
                    .scaleEffect(value == rating ? 1.15 : 1.0)
                    .onTapGesture { rating = value }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: rating)
    }
}

/// Internal (not `private`) — reused by `RateCombinationView.swift`.
struct ConfidenceEmojiRow: View {
    @Binding var rating: Int

    private let emoji = ["😕", "😐", "🙂", "😊", "😍"]

    var body: some View {
        HStack {
            Spacer()
            ForEach(1...5, id: \.self) { value in
                Text(emoji[value - 1])
                    .font(.title)
                    .opacity(value == rating ? 1.0 : 0.35)
                    .scaleEffect(value == rating ? 1.2 : 1.0)
                    .onTapGesture { rating = value }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: rating)
    }
}

private struct WearAgainRow: View {
    @Binding var wearAgain: Bool

    var body: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                wearAgain = true
            } label: {
                Label("Yes", systemImage: "hand.thumbsup.fill")
            }
            .buttonStyle(SecondaryButtonStyle(tint: wearAgain ? .green : .secondary))

            Button {
                wearAgain = false
            } label: {
                Label("No", systemImage: "hand.thumbsdown.fill")
            }
            .buttonStyle(SecondaryButtonStyle(tint: !wearAgain ? .red : .secondary))
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let item = WardrobeItem(
        slot: .top,
        formalityScore: 2.5,
        colorProfile: ColorProfile(primaryHex: "#3A7CA5", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer, .springFall],
        fabricWeight: .light
    )
    RateItemQuestionsViewPreviewHost(item: item)
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}

private struct RateItemQuestionsViewPreviewHost: View {
    @Environment(\.modelContext) private var modelContext
    let item: WardrobeItem
    @State private var viewModel: RateItemViewModel?

    var body: some View {
        Group {
            if let viewModel {
                RateItemQuestionsView(item: item, viewModel: viewModel, submitLabel: "Submit Rating", onSaved: {})
            } else {
                ProgressView()
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = RateItemViewModel(item: item, repository: SwiftDataWardrobeRepository(modelContext: modelContext))
        }
    }
}
