//
//  ClosetView.swift
//  Vision_clother
//
//  Tab 2: My Closet Inventory Grid (PRD.md §4). Four persistent slot
//  sections; empty slots show a Ghost Element (PRD §3.2) rather than a
//  blank state.
//

import SwiftUI
import SwiftData
import UIKit

struct ClosetView: View {
    @Query private var storedItems: [WardrobeItem]
    @State private var isAddItemPresented = false
    @State private var isManualPairingPresented = false
    @State private var selectedSlotForAdd: Slot? = nil
    @State private var detailSelection: DetailSelection? = nil

    private var displayItems: [WardrobeItem] {
        let items = GhostElementProvider.ensureGhostElements(in: storedItems)
        return items.sorted { itemA, itemB in
            let orderA = slotOrder(for: itemA.slot)
            let orderB = slotOrder(for: itemB.slot)
            if orderA != orderB {
                return orderA < orderB
            }
            return itemA.id.uuidString < itemB.id.uuidString
        }
    }

    private func slotOrder(for slot: Slot) -> Int {
        switch slot {
        case .top: return 0
        case .bottom: return 1
        case .footwear: return 2
        case .outerwear: return 3
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Slot.allCases) { slot in
                        slotSection(slot)
                    }
                }
                .padding()
            }
            .navigationTitle("My Closet")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        selectedSlotForAdd = nil
                        isAddItemPresented = true
                    } label: {
                        Label("Add Item", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isManualPairingPresented = true
                    } label: {
                        Label("Try On", systemImage: "person.crop.rectangle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    JobQueueBadgeButton()
                }
            }
            .sheet(isPresented: $isAddItemPresented) {
                AddItemView(defaultSlot: selectedSlotForAdd)
            }
            .sheet(isPresented: $isManualPairingPresented) {
                ManualPairingView()
            }
            .sheet(item: $detailSelection) { selection in
                ItemDetailView(items: selection.items, selectedItemID: selection.id)
            }
        }
    }

    private func slotSection(_ slot: Slot) -> some View {
        let items = displayItems.filter { $0.slot == slot }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(slotTitle(slot))
                    .font(.headline)
                Spacer()
                Button {
                    selectedSlotForAdd = slot
                    isAddItemPresented = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.tint)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 12) {
                ForEach(items, id: \.id) { item in
                    ClosetItemCell(item: item)
                        .onTapGesture {
                            detailSelection = DetailSelection(id: item.id, items: displayItems)
                        }
                }
            }
        }
    }

    private func slotTitle(_ slot: Slot) -> String {
        switch slot {
        case .top: return "Tops"
        case .bottom: return "Bottoms"
        case .footwear: return "Footwear"
        case .outerwear: return "Outerwear"
        }
    }
}

/// Snapshot of the tapped item id and the `displayItems` array it was drawn
/// from, taken together in a single evaluation. `displayItems` is computed
/// and re-evaluated on every access, so capturing the id and array
/// separately (once on tap, once inside the sheet closure) could hand
/// `ItemDetailView` an id from one evaluation and an array from another —
/// this couples them so they always agree. Presenting via `.sheet(item:)`
/// (keyed on this `Identifiable`) also forces a fresh `ItemDetailView`
/// instance per selection, so its `@State` can't go stale across taps.
private struct DetailSelection: Identifiable {
    let id: UUID
    let items: [WardrobeItem]
}

private struct ClosetItemCell: View {
    let item: WardrobeItem

    var body: some View {
        VStack(spacing: 4) {
            swatch
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if item.isGhostElement {
                Text("Starter")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Ingested items (`imageAssetName` set — see `ImageStorage.swift`)
    /// render their actual isolated photo; Ghost Elements have no photo and
    /// fall back to the flat-color swatch from `colorProfile`.
    @ViewBuilder
    private var swatch: some View {
        if let imageAssetName = item.imageAssetName,
           let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
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
    ClosetView()
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}
