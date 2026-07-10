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

struct OutfitCardView: View {
    let outfit: OutfitCombination

    var body: some View {
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
        }
        .padding()
    }

    private func slotRow(title: String, item: WardrobeItem) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
                .frame(width: 44, height: 44)
                .overlay {
                    if item.isGhostElement {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.white)
                    }
                }

            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.pattern.rawValue.capitalized)
                    .font(.subheadline)
            }

            Spacer()
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
