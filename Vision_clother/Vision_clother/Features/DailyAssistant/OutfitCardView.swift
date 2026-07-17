//
//  OutfitCardView.swift
//  Vision_clother
//
//  One flatlay card in the Daily Assistant carousel (PRD.md §4, Tab 1).
//  Ghost elements are scored identically to real items (see
//  Domain/PairCompatibilityScoring.swift) — this view is the only place
//  their provenance is surfaced, via the "Starter Piece" badge.
//

import SwiftUI
import UIKit

struct OutfitCardView: View {
    let outfit: OutfitCombination
    /// Prospective Purchase Evaluation (2026-07-15): the id of the item the
    /// user is considering buying, if this card came from a purchase-check
    /// round — `nil` for every ordinary recommendation card. Drives the
    /// "Considering this?" badge and disables the tap-to-detail gesture,
    /// since that item was never saved to the closet and has no
    /// `ItemDetailView` to show (`repository.delete()` would misfire on it).
    var prospectiveItemID: UUID? = nil

    /// Tapping a slot opens the full item detail (`ItemDetailView`, reused
    /// from the Closet feature) for that exact garment.
    @State private var detailItem: WardrobeItem?

    var body: some View {
        // Previously wrapped in a ScrollView to handle overflow inside
        // TabView(.page)'s clipped frame. Now the card sits inside a
        // fixed-height horizontal ScrollView carousel — no inner vertical
        // scroll needed, and removing it prevents gesture conflicts with
        // the outer vertical ScrollView.
        cardContent
    }

    private var cardContent: some View {
        VStack(spacing: 12) {
            if outfit.containsGhostElements {
                Label("Starter Piece", systemImage: "sparkle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, VCSpacing.sm)
                    .padding(.vertical, VCSpacing.xs)
                    .background(.thinMaterial, in: Capsule())
            }

            VStack(spacing: 8) {
                slotRow(title: "Top", item: outfit.top)
                slotRow(title: "Bottom", item: outfit.bottom)
                slotRow(title: "Footwear", item: outfit.footwear)
                if let outerwear = outfit.outerwear {
                    slotRow(title: "Outerwear", item: outerwear)
                }
                if let headwear = outfit.headwear {
                    slotRow(title: "Headwear", item: headwear)
                }
                if let accessory = outfit.accessory {
                    slotRow(title: "Accessory", item: accessory)
                }
                ForEach(Array(outfit.supplementaryAccessories.enumerated()), id: \.element.id) { index, accessory in
                    slotRow(title: outfit.supplementaryAccessories.count > 1 ? "Accessory \(index + 2)" : "Additional Accessory", item: accessory)
                }
                if let bag = outfit.bag {
                    slotRow(title: "Bag", item: bag)
                }
            }
            .premiumCard(radius: VCRadius.prominent, material: .regularMaterial)

            Text("Match score \(Int(outfit.score * 100))%")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // `structuredRationale` is only set for outfits from the primary
            // recommendation LLM path (PRD §3.7) — outfits from the
            // deterministic fallback engine have none, and simply omit this.
            if let rationale = outfit.structuredRationale {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Why this works")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    RationaleRow(icon: "sparkles", text: rationale.summary)
                }
                .premiumCard(material: .regularMaterial)
            }
        }
        .padding()
        .sheet(item: $detailItem) { item in
            ItemDetailView(items: outfit.items, selectedItemID: item.id)
        }
    }

    private func slotRow(title: String, item: WardrobeItem) -> some View {
        HStack {
            thumbnail(for: item)

            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.displayLabel)
                    .font(.subheadline)
                if item.id == prospectiveItemID {
                    Label("Considering this?", systemImage: "tag")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // The prospective item was never saved to the closet — it has
            // no `ItemDetailView` to show, and that view's Delete action
            // would misfire on an item outside the ModelContext.
            guard !item.isGhostElement, item.id != prospectiveItemID else { return }
            detailItem = item
        }
    }

    /// Ingested items (`imageAssetName` set — see `ImageStorage.swift`)
    /// render their actual isolated photo, matching the pattern used by
    /// `ClosetItemCell.swatch`; Ghost Elements have no photo and fall back
    /// to the flat-color swatch from `colorProfile`.
    @ViewBuilder
    private func thumbnail(for item: WardrobeItem) -> some View {
        CachedWardrobeImage(assetName: item.imageAssetName) { image in
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

struct RationaleRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    OutfitCardView(
        outfit: OutfitCombination(
            itemsBySlot: [
                .top: GhostElementProvider.defaultItem(for: .top)!,
                .bottom: GhostElementProvider.defaultItem(for: .bottom)!,
                .footwear: GhostElementProvider.defaultItem(for: .footwear)!,
            ],
            score: 0.82
        )
    )
}
