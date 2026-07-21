//
//  OverviewView.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 4 — the Insights tab's first (and, for now,
//  only functional) sub-tab: a glanceable summary. `@Query`-backed raw rows
//  follow the same convention `Features/Profile/ProfileView.swift` already
//  established for full-history aggregate reads — declarative binding, not
//  a Service call (Features/CLAUDE.md's "Views never call Services
//  directly" targets imperative Service calls, not @Query). Composition and
//  activity bars use `Features/Insights/InsightCharts.swift`'s Swift Charts
//  components as of Phase 6 (previously hand-rolled GeometryReader bars).
//

import Charts
import SwiftData
import SwiftUI

struct OverviewView: View {
    @Query private var inventory: [WardrobeItem]
    @Query(sort: \ItemRating.recordedAt, order: .reverse) private var itemRatings: [ItemRating]
    @Query(sort: \OutfitFeedback.recordedAt, order: .reverse) private var outfitFeedbacks: [OutfitFeedback]
    @Query(sort: \WornLogEntry.wornAt, order: .reverse) private var wornLogEntries: [WornLogEntry]

    @State private var viewModel = OverviewViewModel()
    @State private var timeRange: AnalyticsTimeRange = .threeMonths

    var body: some View {
        Group {
            if inventory.filter({ !$0.isGhostElement }).isEmpty {
                ContentUnavailableView(
                    "No Wardrobe Yet",
                    systemImage: "tshirt",
                    description: Text("Add a few items to your closet to start seeing insights here.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: VCSpacing.xxl) {
                        TimeRangeSelector(selection: $timeRange)

                        if let summary = viewModel.snapshot?.styleSummary {
                            styleSummaryCard(summary)
                        }

                        if let snapshot = viewModel.snapshot {
                            compositionCard(title: "Top Colors", rows: snapshot.topColors.prefix(4).map { ($0.colorVibe.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, $0.percentage) })
                            compositionCard(title: "Top Categories", rows: snapshot.topCategories.prefix(4).map { ($0.slot.rawValue.capitalized, $0.percentage) })
                            activityCard(snapshot)
                            discoveriesCard(snapshot)
                        }
                    }
                    .padding(VCSpacing.lg)
                }
            }
        }
        .navigationTitle("Overview")
        .task {
            viewModel.loadConfigIfNeeded()
            recompute()
        }
        .onChange(of: timeRange) { recompute() }
        .onChange(of: inventory.count) { recompute() }
        .onChange(of: itemRatings.count) { recompute() }
        .onChange(of: outfitFeedbacks.count) { recompute() }
        .onChange(of: wornLogEntries.count) { recompute() }
    }

    private func recompute() {
        viewModel.recompute(
            inventory: inventory,
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            timeRange: timeRange
        )
    }

    private func styleSummaryCard(_ summary: String) -> some View {
        HStack(alignment: .top, spacing: VCSpacing.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(VCAccentColor.brand)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.subheadline)
                InsightSourceCaption(text: "From your closet's colors and categories")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func compositionCard(title: String, rows: [(label: String, percentage: Double)]) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text(title)
                .font(.headline)
            InsightSourceCaption(text: "From what's currently in your closet")
            RankedBarShareChart(rows: rows.map { .init(id: $0.label, label: $0.label, percentage: $0.percentage) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func activityCard(_ snapshot: AnalyticsAggregator.OverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Text(viewModel.ratingConfidence.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InsightSourceCaption(text: "From your ratings and logged wears")
            PeriodLegend()
            activityRow(label: "Outfits rated", delta: snapshot.ratingActivity)
            activityRow(label: "Wears logged", delta: snapshot.wearLogActivity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func activityRow(label: String, delta: AnalyticsAggregator.ActivityDelta) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
            PeriodComparisonChart(currentCount: delta.currentCount, previousCount: delta.previousCount)
        }
    }

    @ViewBuilder
    private func discoveriesCard(_ snapshot: AnalyticsAggregator.OverviewSnapshot) -> some View {
        if !snapshot.discoveries.isEmpty {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Text("Discoveries")
                    .font(.headline)
                InsightSourceCaption(text: "From your recent ratings, wears, and closet mix")
                ForEach(snapshot.discoveries) { discovery in
                    HStack(alignment: .top, spacing: VCSpacing.sm) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(VCAccentColor.brand)
                        Text(discovery.text)
                            .font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        } else {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Text("Discoveries")
                    .font(.headline)
                Text("Rate a few more outfits and log some wears to unlock personalized insights here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }
}

#Preview {
    NavigationStack {
        OverviewView()
    }
    .modelContainer(
        for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self, WornLogEntry.self],
        inMemory: true
    )
}
