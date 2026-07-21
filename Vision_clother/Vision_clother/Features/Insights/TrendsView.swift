//
//  TrendsView.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 7 — Trends sub-tab: engagement-frequency
//  evolution over time for color/category/pattern/style, via
//  `Features/Insights/InsightCharts.swift`'s `TrendLineChart`.
//  `@Query`-backed raw rows follow the same convention every other Insights
//  screen already established.
//

import Charts
import SwiftData
import SwiftUI

struct TrendsView: View {
    @Query private var inventory: [WardrobeItem]
    @Query(sort: \ItemRating.recordedAt, order: .reverse) private var itemRatings: [ItemRating]
    @Query(sort: \OutfitFeedback.recordedAt, order: .reverse) private var outfitFeedbacks: [OutfitFeedback]
    @Query(sort: \WornLogEntry.wornAt, order: .reverse) private var wornLogEntries: [WornLogEntry]
    @Query(sort: \SavedCombination.savedAt, order: .reverse) private var savedCombinations: [SavedCombination]

    @State private var viewModel = TrendsViewModel()
    @State private var timeRange: AnalyticsTimeRange = .sixMonths

    var body: some View {
        Group {
            if inventory.filter({ !$0.isGhostElement }).isEmpty {
                ContentUnavailableView(
                    "No Wardrobe Yet",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Add a few items to your closet to start seeing trends here.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: VCSpacing.xxl) {
                        TimeRangeSelector(selection: $timeRange)

                        if let snapshot = viewModel.snapshot {
                            trendCard(title: "Color Trend", chart: snapshot.colorTrend)
                            trendCard(title: "Category Trend", chart: snapshot.categoryTrend)
                            trendCard(title: "Pattern Trend", chart: snapshot.patternTrend)
                            trendCard(title: "Style Trend", chart: snapshot.styleTrend)
                        }
                    }
                    .padding(VCSpacing.lg)
                }
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.loadConfigIfNeeded()
            recompute()
        }
        .onChange(of: timeRange) { recompute() }
        .onChange(of: inventory.count) { recompute() }
        .onChange(of: itemRatings.count) { recompute() }
        .onChange(of: outfitFeedbacks.count) { recompute() }
        .onChange(of: wornLogEntries.count) { recompute() }
        .onChange(of: savedCombinations.count) { recompute() }
    }

    private func recompute() {
        viewModel.recompute(
            inventory: inventory,
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            savedCombinations: savedCombinations,
            timeRange: timeRange
        )
    }

    @ViewBuilder
    private func trendCard(title: String, chart: TrendsAggregator.TrendChart) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text(title)
                .font(.headline)
            InsightSourceCaption(text: "From your ratings, feedback, and worn items over time")
            if chart.hasEnoughData {
                TrendLineChart(chart: chart)
            } else {
                Text("Rate a few more outfits and log some wears to unlock this trend.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }
}

#Preview {
    NavigationStack {
        TrendsView()
    }
    .modelContainer(
        for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self, WornLogEntry.self, SavedCombination.self],
        inMemory: true
    )
}
