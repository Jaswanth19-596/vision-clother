//
//  RateCombinationView.swift
//  Vision_clother
//
//  Combination Rating: entry point from `CombinationDetailView` ("Rate this
//  outfit"). Rates the whole outfit first with the dimension-based Level 1 +
//  Level 2 question set and a Favorite/Weakest Item pick
//  (`RateCombinationViewModel`, Stylist Intelligence Engine Phase 1), then
//  sequences through each real item resolved from the combination's
//  top/bottom/footwear/outerwear ids (`CombinationsViewModel.resolveItems(for:)`),
//  reusing `RateItemViewModel`/`RateItemQuestionsView` exactly as
//  `RateOutfitView` does after a Daily Assistant save.
//

import SwiftUI
import SwiftData

struct RateCombinationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let combination: SavedCombination
    /// Real items resolved from `combination`'s slot ids — may be shorter
    /// than 4 if a source item was since deleted, or if the outfit never
    /// had footwear/outerwear resolved (Manual Pairing only selects a
    /// top+bottom).
    let items: [WardrobeItem]

    private enum Step: Equatable {
        case outfit
        case item(Int)

        var identity: String {
            switch self {
            case .outfit: return "outfit"
            case .item(let index): return "item-\(index)"
            }
        }
    }

    @State private var step: Step = .outfit
    @State private var outfitViewModel: RateCombinationViewModel?
    @State private var itemViewModel: RateItemViewModel?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .outfit:
                    if let outfitViewModel {
                        RateCombinationQuestionsView(
                            imageAssetName: combination.imageAssetName,
                            viewModel: outfitViewModel,
                            submitLabel: items.isEmpty ? "Finish" : "Next: Rate Items",
                            onSaved: advanceFromOutfit
                        )
                    } else {
                        ProgressView()
                    }

                case .item(let index):
                    if index < items.count, let itemViewModel {
                        RateItemQuestionsView(
                            item: items[index],
                            viewModel: itemViewModel,
                            submitLabel: index == items.count - 1 ? "Finish" : "Next Item",
                            onSaved: { advanceFromItem(index) }
                        )
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .task(id: step.identity) {
            switch step {
            case .outfit:
                outfitViewModel = RateCombinationViewModel(
                    outfitID: combination.id,
                    items: items,
                    repository: SwiftDataWardrobeRepository(modelContext: modelContext)
                )
            case .item(let index):
                guard index < items.count else { return }
                itemViewModel = RateItemViewModel(
                    item: items[index],
                    repository: SwiftDataWardrobeRepository(modelContext: modelContext)
                )
            }
        }
    }

    private var navigationTitle: String {
        switch step {
        case .outfit: return "Rate This Outfit"
        case .item(let index): return "Rate Item (\(index + 1)/\(items.count))"
        }
    }

    private func advanceFromOutfit() {
        if items.isEmpty {
            dismiss()
        } else {
            step = .item(0)
        }
    }

    private func advanceFromItem(_ index: Int) {
        if index + 1 < items.count {
            step = .item(index + 1)
        } else {
            dismiss()
        }
    }
}

/// The dimension-based outfit rating form (Stylist Intelligence Engine
/// Phase 1): Level 1 (Overall Experience) + Level 2 (Fashion Evaluation) +
/// Favorite/Weakest Item. Each Level 2 question exists because it updates a
/// specific part of the recommendation engine — see
/// `Domain/AttributePreferenceProfile.swift` and
/// `docs/decisions/stylist-intelligence-engine.md` for the mapping.
private struct RateCombinationQuestionsView: View {
    let imageAssetName: String
    @Bindable var viewModel: RateCombinationViewModel
    let submitLabel: String
    let onSaved: () -> Void

    /// Ticks once on a completed save — drives the submit-rating
    /// critical-action haptic.
    @State private var savedTick = 0

    var body: some View {
        Form {
            Section {
                combinationImage
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Overall Satisfaction") {
                StarRatingRow(rating: $viewModel.overallSatisfaction)
            }

            Section("Wear Again?") {
                WearAgainTriStateRow(wearAgain: $viewModel.wearAgain)
            }

            Section("Confidence") {
                Text("How confident did you feel?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ConfidenceEmojiRow(rating: $viewModel.confidence)
            }

            Section("Comfort") {
                StarRatingRow(rating: $viewModel.comfort)
            }

            Section("Occasion Match") {
                Text("Did this outfit suit the occasion?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.occasionMatch)
            }

            Section("Personal Style Match") {
                Text("Did this feel like \u{201C}you\u{201D}?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.styleMatch)
            }

            Section("Color Harmony") {
                Text("How did you like the colors together?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.colorHarmony)
            }

            Section("Fit & Silhouette") {
                Text("Did the overall silhouette feel right?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.silhouette)
            }

            Section("Weather Suitability") {
                Text("Did it feel appropriate for today's weather?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.weatherSuitability)
            }

            Section("Practicality") {
                Text("Could you comfortably wear this for the whole event?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRatingRow(rating: $viewModel.practicality)
            }

            if !viewModel.items.isEmpty {
                Section("Favorite Piece") {
                    Text("Which piece did you like most?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FavoriteWeakestPicker(
                        items: viewModel.items,
                        selection: viewModel.favoriteItemID,
                        onSelect: viewModel.selectFavorite
                    )
                }

                Section("Weakest Piece") {
                    Text("Which piece held the outfit back?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FavoriteWeakestPicker(
                        items: viewModel.items,
                        selection: viewModel.weakestItemID,
                        onSelect: viewModel.selectWeakest
                    )
                }
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
                Text(viewModel.state == .saving ? "Saving\u{2026}" : submitLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.state == .saving)
            .listRowBackground(Color.clear)
        }
        .sensoryFeedback(.success, trigger: savedTick)
    }

    /// Mirrors `CombinationDetailView.CombinationDetailPage.image`'s pattern
    /// — the saved flatlay render, so the user sees the whole outfit while
    /// rating it overall.
    @ViewBuilder
    private var combinationImage: some View {
        if let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(VCRadius.shape(VCRadius.card))
        } else {
            Label("Couldn't load this image", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}

private struct WearAgainTriStateRow: View {
    @Binding var wearAgain: WearAgainAnswer

    var body: some View {
        Picker("Wear again?", selection: $wearAgain) {
            ForEach(WearAgainAnswer.allCases) { answer in
                Text(answer.label).tag(answer)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.vertical, 4)
    }
}

private struct FavoriteWeakestPicker: View {
    let items: [WardrobeItem]
    let selection: UUID?
    let onSelect: (UUID?) -> Void

    var body: some View {
        Picker("Piece", selection: Binding(get: { selection }, set: onSelect)) {
            Text("None").tag(UUID?.none)
            ForEach(items, id: \.id) { item in
                Text(item.slot.rawValue.capitalized).tag(UUID?.some(item.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
