//
//  CombinationsView.swift
//  Vision_clother
//
//  Tab 4: Combinations (see CombinationsViewModel.swift). A segmented list —
//  "Generated" (every `SavedCombination` with a real try-on render) and
//  "Worn" (every combination with at least one `WornLogEntry`, most-recently
//  worn first) — since a combination can be one, the other, both, or
//  (transiently, before any action) neither: a placeholder from "Wearing
//  This Today" has no render, and a generated image nobody has logged
//  wearing yet has no `WornLogEntry`. Tapping a row opens
//  CombinationDetailView full-screen, paging through whichever segment's
//  ordered id list the row came from. Swipe-to-delete removes a row (and its
//  underlying `SavedCombination`) from either segment.
//

import SwiftData
import SwiftUI

private enum CombinationsSegment: String, CaseIterable {
    case generated = "Generated"
    case worn = "Worn"
}

struct CombinationsView: View {
    @Environment(\.modelContext) private var modelContext
    /// Photo-refresh reactivity — see `ClosetView.swift`'s matching comment;
    /// `WardrobeSyncCoordinator`'s background photo prefetch writes
    /// combination renders straight to `ImageStorage`, outside SwiftData.
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator
    @Environment(UsageTracker.self) private var usageTracker
    /// Capped rather than the full all-time history — this backs a
    /// scrollable browse list (unlike `ProfileView`'s aggregate stats, which
    /// genuinely need every row), so showing the most recent
    /// `recentCombinationsLimit` and dropping older ones is a normal,
    /// low-risk pagination trade-off rather than a correctness change.
    @Query(Self.recentCombinationsDescriptor) private var combinations: [SavedCombination]
    /// Backs the "Worn" segment — same pagination posture as `combinations`
    /// above. A worn combination whose `SavedCombination` fell outside
    /// `combinations`'s own cap (or was since deleted) is silently skipped
    /// when joining the two below, same tolerance
    /// `Domain/RecentOutfitHistoryBuilder.swift` already has for orphaned
    /// `WornLogEntry` rows.
    @Query(Self.recentWornLogDescriptor) private var wornLogEntries: [WornLogEntry]
    @State private var viewModel: CombinationsViewModel?
    @State private var segment: CombinationsSegment = .generated
    @State private var detailRequest: DetailRequest?

    static let recentCombinationsLimit = 300
    static let recentWornLogLimit = 300

    static var recentCombinationsDescriptor: FetchDescriptor<SavedCombination> {
        var descriptor = FetchDescriptor<SavedCombination>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        descriptor.fetchLimit = recentCombinationsLimit
        return descriptor
    }

    static var recentWornLogDescriptor: FetchDescriptor<WornLogEntry> {
        var descriptor = FetchDescriptor<WornLogEntry>(sortBy: [SortDescriptor(\.wornAt, order: .reverse)])
        descriptor.fetchLimit = recentWornLogLimit
        return descriptor
    }

    private struct DetailRequest: Identifiable, Hashable {
        let id = UUID()
        let orderedIDs: [UUID]
        let startIndex: Int
    }

    /// Every combination with a real render, most-recently-saved first —
    /// `combinations`'s own sort order, just filtered.
    private var generatedCombinations: [SavedCombination] {
        combinations.filter(\.hasRenderedImage)
    }

    /// One row per outfit, most-recently-worn first: `wornLogEntries` is
    /// already sorted `wornAt` descending, so the first entry seen per
    /// `savedCombinationID` is its most recent wear — repeat wears of the
    /// same outfit collapse rather than producing duplicate rows.
    private var wornCombinations: [(combination: SavedCombination, lastWornAt: Date)] {
        let combinationsByID = Dictionary(uniqueKeysWithValues: combinations.map { ($0.id, $0) })
        var seenCombinationIDs = Set<UUID>()
        var result: [(SavedCombination, Date)] = []
        for entry in wornLogEntries {
            guard seenCombinationIDs.insert(entry.savedCombinationID).inserted else { continue }
            guard let combination = combinationsByID[entry.savedCombinationID] else { continue }
            result.append((combination, entry.wornAt))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Segment", selection: $segment) {
                    ForEach(CombinationsSegment.allCases, id: \.self) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                Group {
                    if let viewModel {
                        content(viewModel: viewModel)
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Combinations")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    JobQueueBadgeButton()
                }
            }
            .navigationDestination(item: $detailRequest) { request in
                if let viewModel {
                    CombinationDetailView(viewModel: viewModel, orderedIDs: request.orderedIDs, startIndex: request.startIndex)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            let repository = SyncingWardrobeRepository(modelContext: modelContext)
            viewModel = CombinationsViewModel(
                repository: repository,
                tryOnService: ServiceFactory.makeTryOnRenderService(repository: repository),
                usageTracker: usageTracker
            )
        }
    }

    @ViewBuilder
    private func content(viewModel: CombinationsViewModel) -> some View {
        switch segment {
        case .generated:
            let rows = generatedCombinations
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Saved Combinations",
                    systemImage: "square.grid.2x2",
                    description: Text("Generate a try-on from Daily Assistant or Try On and tap Save to see it here.")
                )
            } else {
                list(rows.map { (combination: $0, date: $0.savedAt) }, viewModel: viewModel)
            }
        case .worn:
            let rows = wornCombinations
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Worn Outfits Yet",
                    systemImage: "checkmark.circle",
                    description: Text("Swipe an outfit and tap \"Wore This\" to log it here.")
                )
            } else {
                list(rows.map { (combination: $0.combination, date: $0.lastWornAt) }, viewModel: viewModel)
            }
        }
    }

    private func list(_ rows: [(combination: SavedCombination, date: Date)], viewModel: CombinationsViewModel) -> some View {
        let orderedIDs = rows.map(\.combination.id)
        return List {
            ForEach(Array(rows.enumerated()), id: \.element.combination.id) { index, row in
                Button {
                    detailRequest = DetailRequest(orderedIDs: orderedIDs, startIndex: index)
                } label: {
                    CombinationRow(combination: row.combination, date: row.date)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.delete(row.combination)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    // Analytics & Insights, Phase 3 — the lightest-friction
                    // real-world wear signal the app has (see
                    // `Models/WornLogEntry.swift`'s doc comment on the gap
                    // this fills). Tint matches the destructive action's
                    // opposite-edge convention, not semantics. Available in
                    // both segments — logging a repeat wear from the "Worn"
                    // segment is a legitimate re-wear, not a no-op.
                    Button {
                        viewModel.logWorn(row.combination)
                    } label: {
                        Label("Wore This", systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                }
            }
        }
        .id(syncCoordinator.photoRefreshTick)
    }
}

private struct CombinationRow: View {
    let combination: SavedCombination
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 60, height: 60)
                .clipShape(VCRadius.shape(VCRadius.swatch))

            VStack(alignment: .leading, spacing: 4) {
                Text(combination.displayTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        CachedWardrobeImage(assetName: combination.imageAssetName) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            VCRadius.shape(VCRadius.swatch)
                .fill(.thinMaterial)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

#Preview {
    let previewContainer = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self, WornLogEntry.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let previewRepository = SyncingWardrobeRepository(modelContext: previewContainer.mainContext)
    return CombinationsView()
        .modelContainer(previewContainer)
        .environment(UsageTracker(repository: previewRepository, syncService: MockWardrobeSyncService(), entitlementLimitsService: MockEntitlementLimitsService()))
}
