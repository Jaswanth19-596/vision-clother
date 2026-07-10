//
//  RateItemView.swift
//  Vision_clother
//
//  Item Rating & Preference Learning. Single-scroll rating form (Fit,
//  Comfort, Confidence, Wear again?) reusing `AddItemView`'s Form/Section
//  idiom. `RateItemQuestionsView` is the shared question body; `RateItemView`
//  wraps it as a standalone sheet for the "Rate this item" entry point on
//  `Closet/ItemDetailView.swift`. The batch entry point after a try-on save
//  lives in `RateOutfitView.swift`, reusing the same question body.
//

import SwiftUI
import SwiftData

/// Standalone single-item rating sheet — presented from `ItemDetailView`.
struct RateItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let item: WardrobeItem

    @State private var viewModel: RateItemViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    RateItemQuestionsView(viewModel: viewModel, submitLabel: "Submit Rating", onSaved: { dismiss() })
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Rate \(item.displayLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = RateItemViewModel(item: item, repository: SwiftDataWardrobeRepository(modelContext: modelContext))
        }
    }
}

/// The four-question form shared by `RateItemView` (single item) and
/// `RateOutfitView` (sequenced batch after a try-on).
struct RateItemQuestionsView: View {
    @Bindable var viewModel: RateItemViewModel
    let submitLabel: String
    let onSaved: () -> Void

    var body: some View {
        Form {
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
                        onSaved()
                    }
                }
            } label: {
                Text(viewModel.state == .saving ? "Saving…" : submitLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.state == .saving)
            .listRowBackground(Color.clear)
        }
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
}

// MARK: - Question controls

private struct StarRatingRow: View {
    @Binding var rating: Int

    var body: some View {
        HStack {
            Spacer()
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating ? "star.fill" : "star")
                    .foregroundStyle(value <= rating ? .yellow : .secondary)
                    .font(.title2)
                    .onTapGesture { rating = value }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct ConfidenceEmojiRow: View {
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
            .buttonStyle(.bordered)
            .tint(wearAgain ? .green : .secondary)

            Button {
                wearAgain = false
            } label: {
                Label("No", systemImage: "hand.thumbsdown.fill")
            }
            .buttonStyle(.bordered)
            .tint(!wearAgain ? .red : .secondary)
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
    RateItemView(item: item)
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}
