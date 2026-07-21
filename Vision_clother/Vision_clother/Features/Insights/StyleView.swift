//
//  StyleView.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 5 — Style sub-tab's Favorite Colors content
//  (highest priority item per spec). Phase 10 added Style DNA to the bottom
//  of this same screen. `@Query`-backed raw rows follow the same convention
//  `OverviewView.swift`/`ProfileView.swift` already established.
//

import Charts
import SwiftData
import SwiftUI

struct StyleView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var inventory: [WardrobeItem]
    @Query(sort: \ItemRating.recordedAt, order: .reverse) private var itemRatings: [ItemRating]
    @Query(sort: \OutfitFeedback.recordedAt, order: .reverse) private var outfitFeedbacks: [OutfitFeedback]
    @Query(sort: \SavedCombination.savedAt, order: .reverse) private var savedCombinations: [SavedCombination]
    @Query private var wornLogEntries: [WornLogEntry]

    @State private var viewModel: StyleViewModel?
    @State private var comboTimeRange: AnalyticsTimeRange = .threeMonths

    var body: some View {
        Group {
            if inventory.filter({ !$0.isGhostElement }).isEmpty {
                ContentUnavailableView(
                    "No Wardrobe Yet",
                    systemImage: "paintpalette",
                    description: Text("Add a few items to your closet to see your favorite colors here.")
                )
            } else if let viewModel {
                ScrollView {
                    VStack(alignment: .leading, spacing: VCSpacing.xxl) {
                        if let snapshot = viewModel.snapshot {
                            if let whyInsight = snapshot.whyInsight {
                                whyInsightCard(whyInsight)
                            }
                            swatchGalleryCard(title: "Your Colors", swatches: snapshot.primarySwatches)
                            categoryBreakdownCard(snapshot.categoryBreakdown)
                            lightnessCard(snapshot.lightness)
                            undertoneCard(snapshot.undertones)
                            seasonalCard(snapshot.seasonalColors)
                            accentCard(snapshot.accentUsage)
                            combosCard(snapshot.combos)
                        }
                        if let styleDNASnapshot = viewModel.styleDNASnapshot {
                            styleDNACard(styleDNASnapshot)
                        }
                    }
                    .padding(VCSpacing.lg)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Style")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel == nil {
                viewModel = StyleViewModel(repository: SyncingWardrobeRepository(modelContext: modelContext))
            }
            viewModel?.loadConfigIfNeeded()
            recompute()
        }
        .onChange(of: comboTimeRange) { recompute() }
        .onChange(of: inventory.count) { recompute() }
        .onChange(of: itemRatings.count) { recompute() }
        .onChange(of: outfitFeedbacks.count) { recompute() }
        .onChange(of: savedCombinations.count) { recompute() }
        .onChange(of: wornLogEntries.count) { recompute() }
    }

    private func recompute() {
        let detailedOutfitFeedbacks = outfitFeedbacks.filter { $0.normalizedRating != nil }
        viewModel?.recompute(
            inventory: inventory,
            savedCombinations: savedCombinations,
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            ratingSampleSize: itemRatings.count + detailedOutfitFeedbacks.count,
            comboTimeRange: comboTimeRange
        )
    }

    private func whyInsightCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: VCSpacing.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(VCAccentColor.brand)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.subheadline)
                InsightSourceCaption(text: "From your closet colors and past ratings")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func swatchGalleryCard(title: String, swatches: [ColorInsightsAggregator.SwatchShare]) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text(title)
                .font(.headline)
            InsightSourceCaption(text: "From the colors of items in your closet")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VCSpacing.md) {
                    ForEach(swatches.prefix(12)) { swatch in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: swatch.hex) ?? .gray)
                                .frame(width: 36, height: 36)
                                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                            Text("\(swatch.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func categoryBreakdownCard(_ rows: [AnalyticsAggregator.ColorShare]) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text("Color Vibe Breakdown")
                .font(.headline)
            InsightSourceCaption(text: "From the colors of items in your closet")
            RankedBarShareChart(rows: rows.map {
                .init(
                    id: $0.colorVibe.rawValue,
                    label: $0.colorVibe.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                    percentage: $0.percentage
                )
            })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    @ViewBuilder
    private func lightnessCard(_ lightness: ColorInsightsAggregator.LightnessBreakdown) -> some View {
        if lightness.total > 0 {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Text("Dark / Light")
                    .font(.headline)
                InsightSourceCaption(text: "From the colors of items in your closet")
                RankedBarShareChart(rows: [
                    .init(id: "dark", label: "Dark", percentage: lightness.darkPercentage),
                    .init(id: "medium", label: "Medium", percentage: lightness.mediumPercentage),
                    .init(id: "light", label: "Light", percentage: lightness.lightPercentage),
                ])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }

    private func undertoneCard(_ rows: [ColorInsightsAggregator.UndertoneShare]) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text("Warm / Cool")
                .font(.headline)
            InsightSourceCaption(text: "From the colors of items in your closet")
            RankedBarShareChart(rows: rows.map {
                .init(id: $0.undertone?.rawValue ?? "unknown", label: $0.undertone?.rawValue.capitalized ?? "Unknown", percentage: $0.percentage)
            })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    @ViewBuilder
    private func seasonalCard(_ rows: [ColorInsightsAggregator.SeasonalColors]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Text("Seasonal Colors")
                    .font(.headline)
                InsightSourceCaption(text: "From the colors of items in your closet")
                ForEach(rows) { row in
                    HStack {
                        Text(seasonLabel(row.season))
                            .font(.subheadline)
                        Spacer()
                        Text(row.topColors.map { $0.colorVibe.rawValue.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }

    private func accentCard(_ accent: ColorInsightsAggregator.AccentUsage) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text("Primary vs. Accent")
                .font(.headline)
            InsightSourceCaption(text: "From the colors of items in your closet")
            HStack {
                Text("Items with an accent color")
                    .font(.subheadline)
                Spacer()
                Text("\(Int((accent.withAccentPercentage * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !accent.topAccentSwatches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VCSpacing.sm) {
                        ForEach(accent.topAccentSwatches) { swatch in
                            Circle()
                                .fill(Color(hex: swatch.hex) ?? .gray)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func combosCard(_ combos: [ColorInsightsAggregator.ComboShare]) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            HStack {
                Text("Favorite Combos")
                    .font(.headline)
                Spacer()
            }
            InsightSourceCaption(text: "From outfits you've saved")
            TimeRangeSelector(selection: $comboTimeRange)
            if combos.isEmpty {
                Text("Save a few outfits with at least two colors to see your favorite combos here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                RankedBarShareChart(rows: combos.prefix(5).map { combo in
                    .init(
                        id: combo.id,
                        label: "\(combo.colorA.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) + \(combo.colorB.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)",
                        percentage: combo.percentage
                    )
                })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    @ViewBuilder
    private func styleDNACard(_ dna: StyleDNAScorer.StyleDNASnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text("Style DNA")
                .font(.headline)
            InsightSourceCaption(text: "From your ratings, feedback, and worn history")
            if dna.isUnlocked {
                RankedBarShareChart(rows: dna.dimensions.map {
                    .init(id: $0.id, label: $0.name, percentage: $0.score / 100)
                })
                let distinctive = dna.dimensions.sorted { abs($0.score - 50) > abs($1.score - 50) }.prefix(3)
                ForEach(Array(distinctive)) { dimension in
                    HStack(alignment: .top, spacing: VCSpacing.sm) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(VCAccentColor.brand)
                        Text(dimension.why)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                let remaining = max(0, (viewModel?.thresholds ?? .conservativeDefault).styleDNAMinRatings - dna.ratingSampleSize)
                Text("Rate \(remaining) more item\(remaining == 1 ? "" : "s") or outfit\(remaining == 1 ? "" : "s") to unlock your Style DNA.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func seasonLabel(_ season: Season) -> String {
        switch season {
        case .summer: return "Summer"
        case .springFall: return "Spring/Fall"
        case .winter: return "Winter"
        }
    }
}

#Preview {
    NavigationStack {
        StyleView()
    }
    .modelContainer(
        for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self, SavedCombination.self],
        inMemory: true
    )
}
