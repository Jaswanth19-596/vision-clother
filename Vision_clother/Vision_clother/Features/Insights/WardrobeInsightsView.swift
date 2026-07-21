//
//  WardrobeInsightsView.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 8 — Wardrobe sub-tab: utilization, most/least
//  worn, redundant items, and closet balance. Shopping suggestions (Phase 9)
//  join this same screen next, per the Phase 1 plan's nav mapping.
//  `@Query`-backed raw rows follow the same convention every other Insights
//  screen already established.
//

import SwiftData
import SwiftUI

struct WardrobeInsightsView: View {
    @Query private var inventory: [WardrobeItem]
    @Query private var wornLogEntries: [WornLogEntry]

    @State private var viewModel = WardrobeInsightsViewModel()

    private var itemsByID: [UUID: WardrobeItem] {
        Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
    }

    var body: some View {
        Group {
            let realItems = inventory.filter { !$0.isGhostElement }
            if realItems.isEmpty {
                ContentUnavailableView(
                    "No Wardrobe Yet",
                    systemImage: "tshirt",
                    description: Text("Add a few items to your closet to see wardrobe insights here.")
                )
            } else if let snapshot = viewModel.snapshot, !snapshot.hasEnoughItems {
                ContentUnavailableView(
                    "Still Building Your Closet",
                    systemImage: "tshirt",
                    description: Text("Add \(max(0, viewModel.thresholds.wardrobeInsightsMinItems - snapshot.totalRealItems)) more item\(viewModel.thresholds.wardrobeInsightsMinItems - snapshot.totalRealItems == 1 ? "" : "s") to unlock wardrobe insights.")
                )
            } else if let snapshot = viewModel.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: VCSpacing.xxl) {
                        utilizationCard(snapshot)
                        if snapshot.hasEnoughWearData {
                            itemListCard(title: "Most Worn", items: snapshot.mostWorn, emptyText: nil)
                            itemListCard(title: "Rarely or Never Worn", items: snapshot.leastWorn, emptyText: "Every item in your closet has been worn at least once — nice.")
                        }
                        redundantCard(snapshot)
                        balanceCard(snapshot)
                        if let shoppingSnapshot = viewModel.shoppingSnapshot {
                            shoppingCard(shoppingSnapshot)
                        }
                    }
                    .padding(VCSpacing.lg)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Wardrobe")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.loadConfigIfNeeded()
            recompute()
        }
        .onChange(of: inventory.count) { recompute() }
        .onChange(of: wornLogEntries.count) { recompute() }
    }

    private func recompute() {
        viewModel.recompute(inventory: inventory, wornLogEntries: wornLogEntries)
    }

    @ViewBuilder
    private func utilizationCard(_ snapshot: WardrobeInsightsAggregator.WardrobeInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text("Utilization")
                .font(.headline)
            InsightSourceCaption(text: "From wears you've logged")
            if let rate = snapshot.utilizationRate {
                Text("\(Int((rate * 100).rounded()))%")
                    .font(.system(.largeTitle, design: .rounded).bold())
                Text("of your closet has been worn at least once since you started logging.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let remaining = max(0, viewModel.thresholds.wardrobeInsightsMinWornLogs - wornLogEntries.count)
                Text("Log \(remaining) more wear\(remaining == 1 ? "" : "s") to unlock your utilization rate.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Swipe a saved combination and tap \"Wore This\" to log a wear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    @ViewBuilder
    private func itemListCard(title: String, items: [WardrobeInsightsAggregator.ItemUtilization], emptyText: String?) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Text(title)
                    .font(.headline)
                InsightSourceCaption(text: "From wears you've logged")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VCSpacing.md) {
                        ForEach(items) { utilization in
                            if let item = itemsByID[utilization.itemID] {
                                itemChip(item: item, caption: utilization.wearCount > 0 ? "Worn \(utilization.wearCount)×" : "Never worn")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        } else if let emptyText {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Text(title)
                    .font(.headline)
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }

    @ViewBuilder
    private func redundantCard(_ snapshot: WardrobeInsightsAggregator.WardrobeInsightsSnapshot) -> some View {
        if !snapshot.redundantGroups.isEmpty {
            VStack(alignment: .leading, spacing: VCSpacing.lg) {
                Text("Similar Items")
                    .font(.headline)
                InsightSourceCaption(text: "From what's in your closet")
                ForEach(snapshot.redundantGroups) { group in
                    VStack(alignment: .leading, spacing: VCSpacing.sm) {
                        Text("\(group.itemIDs.count) similar \(group.pattern.rawValue) \(group.colorVibe.rawValue.replacingOccurrences(of: "_", with: " ")) \(group.slot.rawValue)s")
                            .font(.subheadline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: VCSpacing.md) {
                                ForEach(group.itemIDs, id: \.self) { itemID in
                                    if let item = itemsByID[itemID] {
                                        let wearCount = snapshot.mostWorn.first { $0.itemID == itemID }?.wearCount
                                        itemChip(item: item, caption: snapshot.hasEnoughWearData ? "Worn \(wearCount ?? 0)×" : nil)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }

    private func balanceCard(_ snapshot: WardrobeInsightsAggregator.WardrobeInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Text("Closet Balance")
                .font(.headline)
            InsightSourceCaption(text: "From what's in your closet")
            RankedBarShareChart(rows: snapshot.slotBalance.map {
                .init(id: $0.slot.rawValue, label: $0.slot.rawValue.capitalized, percentage: $0.percentage)
            })
            if let bottleneck = snapshot.bottleneckSlot {
                let count = snapshot.slotBalance.first { $0.slot == bottleneck }?.count ?? 0
                HStack(alignment: .top, spacing: VCSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(VCAccentColor.brand)
                    Text("\(bottleneck.rawValue.capitalized) is your smallest essential category (\(count) item\(count == 1 ? "" : "s")) — this caps how many complete outfits your wardrobe can produce.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    @ViewBuilder
    private func shoppingCard(_ shopping: ShoppingInsightsAggregator.ShoppingInsightsSnapshot) -> some View {
        if !shopping.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: VCSpacing.sm) {
                Text("Shopping Suggestions")
                    .font(.headline)
                InsightSourceCaption(text: "From gaps between what you own and what you actually wear")
                ForEach(shopping.suggestions) { suggestion in
                    HStack(alignment: .top, spacing: VCSpacing.sm) {
                        Image(systemName: "bag")
                            .foregroundStyle(VCAccentColor.brand)
                        Text(suggestion.text)
                            .font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumCard()
        }
    }

    private func itemChip(item: WardrobeItem, caption: String?) -> some View {
        VStack(spacing: 4) {
            CachedWardrobeImage(assetName: item.imageAssetName) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                VCRadius.shape(VCRadius.swatch)
                    .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
            }
            .frame(width: 56, height: 56)
            .clipShape(VCRadius.shape(VCRadius.swatch))

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64)
    }
}

#Preview {
    NavigationStack {
        WardrobeInsightsView()
    }
    .modelContainer(
        for: [WardrobeItem.self, WornLogEntry.self],
        inMemory: true
    )
}
