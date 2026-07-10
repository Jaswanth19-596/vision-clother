//
//  ItemDetailView.swift
//  Vision_clother
//
//  Read-only detail sheet for closet items. Supports page-swiping across all
//  available items in the closet. Shows the full garment photo (or color swatch
//  for ghost/manual items) and all metadata attributes. Real items can be
//  deleted; Ghost Elements cannot (see PRD §3.2).
//

import SwiftUI
import SwiftData
import UIKit

struct ItemDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State var items: [WardrobeItem]
    @State var selectedItemID: UUID

    @State private var isDeleteAlertPresented = false
    @State private var isRateSheetPresented = false

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedItemID) {
                ForEach(items, id: \.id) { item in
                    ScrollView {
                        VStack(spacing: 24) {
                            garmentPreview(for: item)
                            metadataSection(for: item)
                            if !item.isGhostElement {
                                rateButton
                            }
                        }
                        .padding()
                    }
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(currentSlotLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let currentItem, !currentItem.isGhostElement {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) {
                            isDeleteAlertPresented = true
                        }
                    }
                }
            }
            .sheet(isPresented: $isRateSheetPresented) {
                if let currentItem {
                    RateItemView(item: currentItem)
                }
            }
            .alert("Delete this item?", isPresented: $isDeleteAlertPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    deleteCurrentItem()
                }
            } message: {
                Text("This garment will be permanently removed from your closet.")
            }
        }
    }

    private var currentItem: WardrobeItem? {
        items.first { $0.id == selectedItemID }
    }

    private var currentSlotLabel: String {
        guard let slot = currentItem?.slot else { return "" }
        switch slot {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .footwear: return "Footwear"
        case .outerwear: return "Outerwear"
        }
    }

    // MARK: - Garment Preview

    @ViewBuilder
    private func garmentPreview(for item: WardrobeItem) -> some View {
        if let imageAssetName = item.imageAssetName,
           let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16)
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

    // MARK: - Rating

    private var rateButton: some View {
        Button {
            isRateSheetPresented = true
        } label: {
            Label("Rate this item", systemImage: "star.bubble")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Metadata

    private func metadataSection(for item: WardrobeItem) -> some View {
        VStack(spacing: 0) {
            metadataRow("Category", value: item.slot.rawValue.capitalized)
            Divider()
            metadataRow("Formality", value: formalityLabel(for: item))
            Divider()
            metadataRow("Pattern", value: item.pattern.rawValue.capitalized)
            Divider()
            metadataRow("Color Vibe", value: item.colorProfile.category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            Divider()
            metadataRow("Fabric Weight", value: item.fabricWeight.rawValue.capitalized)
            Divider()
            metadataRow("Seasons", value: seasonLabel(for: item))
            Divider()
            colorRow(for: item)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func colorRow(for item: WardrobeItem) -> some View {
        HStack {
            Text("Color")
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
                    }
                Text(item.colorProfile.primaryHex)
                    .font(.footnote)
                    .monospaced()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func formalityLabel(for item: WardrobeItem) -> String {
        let score = item.formalityScore
        let descriptor: String
        switch score {
        case ..<2.0: descriptor = "Casual"
        case 2.0..<3.5: descriptor = "Smart-Casual"
        default: descriptor = "Formal"
        }
        return "\(String(format: "%.1f", score)) — \(descriptor)"
    }

    private func seasonLabel(for item: WardrobeItem) -> String {
        item.seasonality
            .map { $0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
            .joined(separator: ", ")
    }

    // MARK: - Actions

    private func deleteCurrentItem() {
        guard let itemToDelete = currentItem else { return }

        let repository = SwiftDataWardrobeRepository(modelContext: modelContext)
        do {
            try repository.delete(itemToDelete)

            // Transition active selection before removing item from array
            if let index = items.firstIndex(where: { $0.id == itemToDelete.id }) {
                let nextSelectionID: UUID?
                if items.count > 1 {
                    if index + 1 < items.count {
                        nextSelectionID = items[index + 1].id
                    } else {
                        nextSelectionID = items[index - 1].id
                    }
                } else {
                    nextSelectionID = nil
                }

                withAnimation {
                    items.remove(at: index)
                    if let nextSelectionID {
                        selectedItemID = nextSelectionID
                    } else {
                        dismiss()
                    }
                }
            } else {
                dismiss()
            }
        } catch {
            print("⚠️ Failed to delete item: \(error)")
            dismiss()
        }
    }
}

#Preview {
    let item1 = WardrobeItem(
        slot: .top,
        formalityScore: 2.5,
        colorProfile: ColorProfile(primaryHex: "#3A7CA5", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer, .springFall],
        fabricWeight: .light
    )
    let item2 = WardrobeItem(
        slot: .bottom,
        formalityScore: 3.0,
        colorProfile: ColorProfile(primaryHex: "#222222", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer, .springFall, .winter],
        fabricWeight: .medium
    )

    ItemDetailView(items: [item1, item2], selectedItemID: item1.id)
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}
