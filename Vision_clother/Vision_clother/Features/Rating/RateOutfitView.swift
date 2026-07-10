//
//  RateOutfitView.swift
//  Vision_clother
//
//  Item Rating & Preference Learning: after a try-on save (Daily Assistant
//  or Manual Pairing), sequences the same `RateItemQuestionsView` form
//  (RateItemView.swift) across every real item in the saved outfit — one
//  question-set per item, "Next Item" / "Finish" advancing through them.
//  Ghost Elements are excluded by the caller (see `items` doc below): they
//  have no real garment to rate.
//

import SwiftUI
import SwiftData

struct RateOutfitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Real (non-ghost) items from the saved outfit. Callers are
    /// responsible for filtering out `isGhostElement` items before
    /// presenting this view — see `WardrobeItem.isGhostElement`.
    let items: [WardrobeItem]

    @State private var index = 0
    @State private var viewModel: RateItemViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    RateItemQuestionsView(
                        viewModel: viewModel,
                        submitLabel: isLastItem ? "Finish" : "Next Item",
                        onSaved: advance
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Rate Your Outfit (\(index + 1)/\(items.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .task(id: index) {
            guard index < items.count else { return }
            viewModel = RateItemViewModel(item: items[index], repository: SwiftDataWardrobeRepository(modelContext: modelContext))
        }
    }

    private var isLastItem: Bool {
        index >= items.count - 1
    }

    private func advance() {
        if index + 1 < items.count {
            index += 1
        } else {
            dismiss()
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
    RateOutfitView(items: [top, bottom])
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}
