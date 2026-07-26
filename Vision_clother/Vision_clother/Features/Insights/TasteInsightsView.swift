//
//  TasteInsightsView.swift
//  Vision_clother
//
//  Analytics & Insights — "Taste" sub-tab (formerly the empty "Discover"
//  placeholder). The one Insights surface that shows the user their own
//  learned preferences rather than closet statistics: per attribute
//  dimension, the values they gravitate toward vs. avoid, as ranked affinity
//  bars off the unified `AttributePreferenceProfile`. Reuses the shared
//  `RankedBarShareChart` / `InsightSourceCaption` / `.premiumCard` primitives
//  every other sub-tab already uses.
//

import SwiftData
import SwiftUI

struct TasteInsightsView: View {
    @Environment(\.modelContext) private var modelContext
    // Recompute whenever the signals that feed the profile change. Swipes are
    // local-only events, but returning to this tab re-fires `.task` → recompute.
    @Query private var inventory: [WardrobeItem]
    @Query private var itemRatings: [ItemRating]
    @Query private var outfitFeedbacks: [OutfitFeedback]

    @State private var viewModel: TasteInsightsViewModel?

    var body: some View {
        Group {
            if let viewModel, let snapshot = viewModel.snapshot {
                if snapshot.hasSignal, !snapshot.dimensions.isEmpty {
                    content(snapshot)
                } else {
                    stillLearning
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Taste")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel == nil {
                viewModel = TasteInsightsViewModel(repository: SyncingWardrobeRepository(modelContext: modelContext))
            }
            viewModel?.recompute(inventory: inventory)
        }
        .onChange(of: inventory.count) { viewModel?.recompute(inventory: inventory) }
        .onChange(of: itemRatings.count) { viewModel?.recompute(inventory: inventory) }
        .onChange(of: outfitFeedbacks.count) { viewModel?.recompute(inventory: inventory) }
    }

    private func content(_ snapshot: TasteInsightsSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VCSpacing.xxl) {
                fingerprintCard(snapshot.fingerprint)
                if let alignment = viewModel?.alignment, alignment.hasSignal {
                    alignmentCard(alignment)
                }
                ForEach(snapshot.dimensions) { dimension in
                    dimensionCard(dimension)
                }
            }
            .padding(VCSpacing.lg)
        }
    }

    /// Taste vs. closet: the headline alignment score plus the "worth adding"
    /// (loved-but-under-owned) and "worth a second look" (over-owned) lists.
    /// Reuses the same `SwatchCluster` / `InsightSourceCaption` / `.premiumCard`
    /// primitives as the affinity cards below it.
    @ViewBuilder
    private func alignmentCard(_ alignment: TasteClosetAlignmentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: VCSpacing.sm) {
                Label("Taste vs. Your Closet", systemImage: "scalemass")
                    .font(.headline)
                Spacer()
                Text("\(alignment.alignmentScore)%")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(VCAccentColor.brand)
            }
            InsightSourceCaption(text: "How well what you own matches what you love")
            Text(alignment.headline)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !alignment.buyMore.isEmpty {
                divergenceSection(title: "Worth adding", icon: "plus.circle.fill",
                                  tint: .green, rows: alignment.buyMore)
            }
            if !alignment.reconsider.isEmpty {
                divergenceSection(title: "Worth a second look", icon: "arrow.uturn.backward.circle.fill",
                                  tint: .secondary, rows: alignment.reconsider)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func divergenceSection(
        title: String, icon: String, tint: Color,
        rows: [TasteClosetAlignmentSnapshot.Divergence]
    ) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.xs) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .padding(.top, VCSpacing.xs)
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: VCSpacing.sm) {
                    if !row.swatchHexes.isEmpty {
                        SwatchCluster(hexes: row.swatchHexes)
                    }
                    Text(row.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func fingerprintCard(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Label("Your Style Fingerprint", systemImage: "sparkles")
                .font(.headline)
            InsightSourceCaption(text: "Learned from your swipes and feedback")
            Text(fingerprint)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    @ViewBuilder
    private func dimensionCard(_ dimension: TasteInsightsSnapshot.Dimension) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text(dimension.title)
                .font(.headline)
            if let caption = dimension.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InsightSourceCaption(text: "50% is neutral — higher means you're drawn to it")
            VStack(spacing: VCSpacing.sm) {
                ForEach(dimension.rows) { row in
                    TasteBarRow(row: row)
                }
            }
            .padding(.top, 2)
            if !dimension.loved.isEmpty {
                lovedAvoidRow(icon: "heart.fill", tint: .green,
                              lead: "You love", values: dimension.loved)
            }
            if !dimension.avoided.isEmpty {
                lovedAvoidRow(icon: "hand.thumbsdown.fill", tint: .secondary,
                              lead: "You avoid", values: dimension.avoided)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func lovedAvoidRow(icon: String, tint: Color, lead: String, values: [String]) -> some View {
        HStack(alignment: .top, spacing: VCSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.caption)
            Text("**\(lead):** \(values.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stillLearning: some View {
        ContentUnavailableView {
            Label("Still Learning Your Taste", systemImage: "sparkle.magnifyingglass")
        } description: {
            Text("Swipe a few looks in the Discover deck and rate some outfits — your color, fit, and material preferences will show up here.")
        }
    }
}

/// One value's affinity as an overflow-safe row: optional colour swatches, a
/// truncation-safe label in a fixed column, a proportional bar with a neutral
/// tick at 50%, and an inline percentage. Everything is fixed-width or
/// flexible-fill, so nothing can run off the card edge (the reason the old
/// `RankedBarShareChart` reuse was dropped here).
private struct TasteBarRow: View {
    let row: TasteInsightsSnapshot.Row

    private var fillColor: Color {
        if row.affinity > TasteInsightsAggregator.lovedThreshold { return VCAccentColor.brand }
        if row.affinity < TasteInsightsAggregator.avoidThreshold { return Color(.systemGray3) }
        return VCAccentColor.brand.opacity(0.5)
    }

    var body: some View {
        HStack(spacing: VCSpacing.sm) {
            if !row.swatchHexes.isEmpty {
                SwatchCluster(hexes: row.swatchHexes)
            }
            Text(row.label)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 100, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                        .frame(height: 8)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(4, w * row.affinity), height: 8)
                    Rectangle()
                        .fill(Color(.systemGray2))
                        .frame(width: 1, height: 12)
                        .position(x: w * 0.5, y: geo.size.height / 2)
                }
            }
            .frame(height: 14)
            Text("\(Int((row.affinity * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

/// A little cluster of representative colour swatches (hairline-bordered so
/// white/pastel stay visible), used by the colour-based Taste dimensions.
private struct SwatchCluster: View {
    let hexes: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(hexes.prefix(4).enumerated()), id: \.offset) { _, hex in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: hex) ?? .gray)
                    .frame(width: 11, height: 11)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(.systemGray3), lineWidth: 0.5)
                    )
            }
        }
    }
}

#Preview {
    NavigationStack {
        TasteInsightsView()
    }
    .modelContainer(
        for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self],
        inMemory: true
    )
}
