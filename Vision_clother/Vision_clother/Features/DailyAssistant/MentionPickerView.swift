//
//  MentionPickerView.swift
//  Vision_clother
//
//  @-mention feature (2026-07-24): the picker presented when the user types
//  "@" in the Daily Assistant prompt field (or taps the "Add items" button).
//  Lets them select specific wardrobe items to reference in their message so
//  the LLM can resolve "these"/"this" to real owned garments — see
//  `DailyAssistantViewModel.mentionedItems`.
//
//  IMPORTANT: the thumbnails here are display-only, to help the user pick.
//  Only the selected items' text descriptions + ids are ever sent to the LLM
//  (`DailyAssistantViewModel.referencedItemsText`), never their images — the
//  same text-only-catalog invariant the recommendation/QA calls already hold
//  (docs/decisions/resolved-v1.md).
//

import SwiftUI

struct MentionPickerView: View {
    /// `@Bindable` so row taps reading `viewModel.mentionedItems` re-render as
    /// selection changes — the view model is `@Observable`.
    @Bindable var viewModel: DailyAssistantViewModel
    let onDone: () -> Void

    /// Loaded once on appear rather than re-fetched every body evaluation —
    /// `mentionCandidates()` is cheap (version-cached), but the slot grouping
    /// below shouldn't rerun on every selection toggle.
    @State private var candidates: [WardrobeItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No items to reference",
                        systemImage: "tshirt",
                        description: Text("Add items to your closet first, then you can @-mention them here.")
                    )
                } else {
                    List {
                        ForEach(slotsWithItems, id: \.self) { slot in
                            Section(slot.rawValue.capitalized) {
                                ForEach(items(in: slot)) { item in
                                    row(for: item)
                                }
                            }
                        }
                    }
                }
            }
            .vcAnimation(VCMotion.contentFade, value: candidates.isEmpty)
            .navigationTitle("Reference Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
        .task { candidates = viewModel.mentionCandidates() }
    }

    /// Only the slots that actually have candidates, in canonical `Slot` order
    /// — an empty "Headwear" section would just be noise.
    private var slotsWithItems: [Slot] {
        Slot.allCases.filter { slot in candidates.contains { $0.slot == slot } }
    }

    private func items(in slot: Slot) -> [WardrobeItem] {
        candidates.filter { $0.slot == slot }
    }

    private func isSelected(_ item: WardrobeItem) -> Bool {
        viewModel.mentionedItems.contains { $0.id == item.id }
    }

    @ViewBuilder
    private func row(for item: WardrobeItem) -> some View {
        Button {
            if isSelected(item) {
                viewModel.removeMention(item)
            } else {
                viewModel.addMention(item)
            }
        } label: {
            HStack(spacing: 12) {
                thumbnail(for: item)

                Text(item.displayLabel)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isSelected(item) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected(item) ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    .contentTransition(.symbolEffect(.replace))
                    .vcAnimation(VCMotion.interactive, value: isSelected(item))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Same isolated-photo-or-color-swatch pattern as `OutfitCardView.thumbnail`.
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
        }
    }
}
