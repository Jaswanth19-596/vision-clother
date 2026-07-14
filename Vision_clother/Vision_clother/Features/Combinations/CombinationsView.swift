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
    @State private var viewModel: CombinationsViewModel?
    @State private var selectedIndex: Int?

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
            viewModel = CombinationsViewModel(repository: SwiftDataWardrobeRepository(modelContext: modelContext))
        }
        .onAppear {
            viewModel?.loadCombinations()
        }
    }

    @ViewBuilder
    private func content(viewModel: CombinationsViewModel) -> some View {
        if viewModel.combinations.isEmpty {
            ContentUnavailableView(
                "No Saved Combinations",
                systemImage: "square.grid.2x2",
                description: Text("Generate a try-on from Daily Assistant or Try On and tap Save to see it here.")
            )
        } else {
            List {
                ForEach(Array(viewModel.combinations.enumerated()), id: \.element.id) { index, combination in
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
        if let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: combination.imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
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
