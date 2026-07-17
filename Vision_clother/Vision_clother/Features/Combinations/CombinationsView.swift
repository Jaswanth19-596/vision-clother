//
//  CombinationsView.swift
//  Vision_clother
//
//  Tab 4: Combinations (see CombinationsViewModel.swift). A list of every
//  saved try-on image; tapping a row opens CombinationDetailView full-screen
//  at that row's index, from which the user can swipe to adjacent saved
//  combinations. Swipe-to-delete removes a row directly from the list.
//

import SwiftData
import SwiftUI

struct CombinationsView: View {
    @Environment(\.modelContext) private var modelContext
    /// Photo-refresh reactivity — see `ClosetView.swift`'s matching comment;
    /// `WardrobeSyncCoordinator`'s background photo prefetch writes
    /// combination renders straight to `ImageStorage`, outside SwiftData.
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator
    /// Capped rather than the full all-time history — this backs a
    /// scrollable browse list (unlike `ProfileView`'s aggregate stats, which
    /// genuinely need every row), so showing the most recent
    /// `recentCombinationsLimit` and dropping older ones is a normal,
    /// low-risk pagination trade-off rather than a correctness change.
    @Query(Self.recentCombinationsDescriptor) private var combinations: [SavedCombination]
    @State private var viewModel: CombinationsViewModel?
    @State private var selectedIndex: Int?

    static let recentCombinationsLimit = 300

    static var recentCombinationsDescriptor: FetchDescriptor<SavedCombination> {
        var descriptor = FetchDescriptor<SavedCombination>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        descriptor.fetchLimit = recentCombinationsLimit
        return descriptor
    }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Combinations")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    JobQueueBadgeButton()
                }
            }
            .navigationDestination(item: $selectedIndex) { index in
                if let viewModel {
                    CombinationDetailView(viewModel: viewModel, startIndex: index)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = CombinationsViewModel(repository: SyncingWardrobeRepository(modelContext: modelContext))
        }
    }

    @ViewBuilder
    private func content(viewModel: CombinationsViewModel) -> some View {
        if combinations.isEmpty {
            ContentUnavailableView(
                "No Saved Combinations",
                systemImage: "square.grid.2x2",
                description: Text("Generate a try-on from Daily Assistant or Try On and tap Save to see it here.")
            )
        } else {
            List {
                ForEach(Array(combinations.enumerated()), id: \.element.id) { index, combination in
                    Button {
                        selectedIndex = index
                    } label: {
                        CombinationRow(combination: combination)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.delete(combination)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .id(syncCoordinator.photoRefreshTick)
        }
    }
}

private struct CombinationRow: View {
    let combination: SavedCombination

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 60, height: 60)
                .clipShape(VCRadius.shape(VCRadius.swatch))

            VStack(alignment: .leading, spacing: 4) {
                Text(combination.displayTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(combination.savedAt, style: .date)
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
    CombinationsView()
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self],
            inMemory: true
        )
}
