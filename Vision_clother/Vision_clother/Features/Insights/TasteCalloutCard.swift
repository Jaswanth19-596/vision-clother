//
//  TasteCalloutCard.swift
//  Vision_clother
//
//  Compact "here's what we've learned about you" card shared by the
//  Overview, Trends, and Wardrobe sub-tabs, so every Insights screen reflects
//  the user's own taste (not just closet statistics) and links back to the
//  full "Taste" tab. Reads the same `TasteInsightsSnapshot` the Taste tab
//  renders; renders nothing until the profile has real signal.
//

import SwiftUI

struct TasteCalloutCard: View {
    let snapshot: TasteInsightsSnapshot?

    var body: some View {
        if let snapshot, snapshot.hasSignal {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Label("Your Taste", systemImage: "heart.text.square")
                    .font(.headline)
                InsightSourceCaption(text: "Learned from your swipes and feedback")
                Text(snapshot.fingerprint)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                let chips = topLovedChips(snapshot)
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VCSpacing.sm) {
                            ForEach(chips, id: \.self) { chip in
                                Text(chip)
                                    .font(.caption)
                                    .padding(.horizontal, VCSpacing.sm)
                                    .padding(.vertical, 4)
                                    .background(VCAccentColor.brand.opacity(0.12), in: Capsule())
                                    .foregroundStyle(VCAccentColor.brand)
                            }
                        }
                    }
                }
                Text("See the full breakdown in the Taste tab.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }

    /// The single strongest loved value from the first few dimensions that
    /// have one — a quick "you love X, Y, Z" glance without the full charts.
    private func topLovedChips(_ snapshot: TasteInsightsSnapshot) -> [String] {
        var chips: [String] = []
        for dimension in snapshot.dimensions {
            if let top = dimension.loved.first {
                chips.append(top)
            }
            if chips.count == 4 { break }
        }
        return chips
    }
}
