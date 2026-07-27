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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Recompute whenever the signals that feed the profile change. Swipes are
    // local-only events, but returning to this tab re-fires `.task` → recompute.
    @Query private var inventory: [WardrobeItem]
    @Query private var itemRatings: [ItemRating]
    @Query private var outfitFeedbacks: [OutfitFeedback]

    @State private var viewModel = TasteInsightsViewModel()
    /// Which dimension cards have their per-category breakdown expanded.
    /// Collapsed by default so the tab still opens on the overall picture —
    /// the breakdown is the "why", not the headline.
    @State private var expandedCategoryDimensions: Set<String> = []

    var body: some View {
        Group {
            if let snapshot = viewModel.snapshot {
                if snapshot.hasSignal, !snapshot.dimensions.isEmpty {
                    content(snapshot)
                } else {
                    stillLearning
                }
            } else {
                // The taste snapshot is inherently derived from an async
                // repository fetch (unlike Overview/Trends/Wardrobe's
                // synchronous aggregation), so a brief loading state here is
                // unavoidable — but it no longer compounds with a deferred
                // view-model construction step the way it used to.
                ProgressView()
            }
        }
        .navigationTitle("Taste")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            recompute()
        }
        .onChange(of: inventory.count) { recompute() }
        .onChange(of: itemRatings.count) { recompute() }
        .onChange(of: outfitFeedbacks.count) { recompute() }
    }

    private func recompute() {
        viewModel.recompute(inventory: inventory, repository: SyncingWardrobeRepository(modelContext: modelContext))
    }

    private func content(_ snapshot: TasteInsightsSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VCSpacing.xxl) {
                fingerprintCard(snapshot.fingerprint)
                if let alignment = viewModel.alignment, alignment.hasSignal {
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
                    AffinityBarRow(label: row.label, affinity: row.affinity, swatchHexes: row.swatchHexes)
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
            if !dimension.categories.isEmpty {
                categoryBreakdown(dimension)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    /// Category-partitioned taste: the same dimension, split per garment
    /// category. Collapsed behind a toggle so a card with seven slots of data
    /// doesn't bury the overall ranking above it.
    @ViewBuilder
    private func categoryBreakdown(_ dimension: TasteInsightsSnapshot.Dimension) -> some View {
        let isExpanded = expandedCategoryDimensions.contains(dimension.id)
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Divider()
                .padding(.vertical, VCSpacing.xs)
            Button {
                withAnimation(vcMotion(VCMotion.standard, reduceMotion: reduceMotion)) {
                    if isExpanded {
                        expandedCategoryDimensions.remove(dimension.id)
                    } else {
                        expandedCategoryDimensions.insert(dimension.id)
                    }
                }
            } label: {
                HStack(spacing: VCSpacing.xs) {
                    Text("By category")
                        .font(.subheadline.weight(.semibold))
                    Text("(\(dimension.categories.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                InsightSourceCaption(text: "The same taste, split by garment category — what you like in tops isn't what you like in shoes")
                ForEach(dimension.categories) { category in
                    VStack(alignment: .leading, spacing: VCSpacing.xs) {
                        Text(category.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(category.rows) { row in
                            AffinityBarRow(label: row.label, affinity: row.affinity, swatchHexes: row.swatchHexes)
                        }
                    }
                    .padding(.top, VCSpacing.xs)
                }
            }
        }
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

#Preview {
    NavigationStack {
        TasteInsightsView()
    }
    .modelContainer(
        for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self],
        inMemory: true
    )
}
