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

    /// Tapping a slot opens the full item detail (`ItemDetailView`, reused
    /// from the Closet feature) for that exact garment.
    @State private var detailItem: WardrobeItem?

    var body: some View {
        // The parent `TabView(.page)` in `DailyAssistantView` gives each card
        // a fixed height (page-style tab views have no intrinsic sizing) —
        // an internal `ScrollView` keeps longer content (e.g. a full
        // rationale block at large Dynamic Type sizes) reachable instead of
        // silently clipped by the page's bounds.
        ScrollView {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(spacing: 12) {
            if outfit.containsGhostElements {
                Label("Starter Piece", systemImage: "sparkle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }

            VStack(spacing: 8) {
                slotRow(title: "Top", item: outfit.top)
                slotRow(title: "Bottom", item: outfit.bottom)
                slotRow(title: "Footwear", item: outfit.footwear)
                if let outerwear = outfit.outerwear {
                    slotRow(title: "Outerwear", item: outerwear)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

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

                    VStack(alignment: .leading, spacing: 6) {
                        RationaleRow(icon: "calendar", text: rationale.occasion)
                        RationaleRow(icon: "paintpalette", text: rationale.colorHarmony)
                        RationaleRow(icon: "figure.stand", text: rationale.bodyProfile)
                        RationaleRow(icon: "cloud.sun", text: rationale.weather)
                        RationaleRow(icon: "star", text: rationale.style)
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !item.isGhostElement else { return }
            detailItem = item
        }
    }

    /// Ingested items (`imageAssetName` set — see `ImageStorage.swift`)
    /// render their actual isolated photo, matching the pattern used by
    /// `ClosetItemCell.swatch`; Ghost Elements have no photo and fall back
    /// to the flat-color swatch from `colorProfile`.
    @ViewBuilder
    private func thumbnail(for item: WardrobeItem) -> some View {
        if let imageAssetName = item.imageAssetName,
           let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
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
            top: GhostElementProvider.defaultItem(for: .top),
            bottom: GhostElementProvider.defaultItem(for: .bottom),
            footwear: GhostElementProvider.defaultItem(for: .footwear),
            outerwear: nil,
            score: 0.82
        )
    )
}
