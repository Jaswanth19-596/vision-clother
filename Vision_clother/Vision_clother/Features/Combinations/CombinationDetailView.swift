//
//  CombinationDetailView.swift
//  Vision_clother
//
//  Full-screen page view over CombinationsViewModel.combinations, opened at
//  the tapped row's index. Paging lets the user swipe to adjacent saved
//  combinations without going back to the list; toolbar Delete removes
//  whichever page is currently showing.
//

import SwiftData
import SwiftUI

struct CombinationDetailView: View {
    let viewModel: CombinationsViewModel
    let startIndex: Int

    /// Own live query rather than reading `viewModel.combinations` — this
    /// view can stay open while a background pull inserts/deletes rows out
    /// from under it (`Data/WardrobeSyncCoordinator.swift`); a `@Query`
    /// re-resolves automatically instead of paging through a stale/detached
    /// snapshot.
    @Query(sort: \SavedCombination.savedAt, order: .reverse) private var combinations: [SavedCombination]
    /// Photo-refresh reactivity — see `ClosetView.swift`'s matching comment.
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var rateSheetCombination: SavedCombination?

    var body: some View {
        TabView(selection: $selectedID) {
            ForEach(combinations, id: \.id) { combination in
                CombinationDetailPage(
                    combination: combination,
                    photoRefreshTick: syncCoordinator.photoRefreshTick,
                    onRate: { rateSheetCombination = combination }
                )
                .tag(Optional(combination.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    deleteCurrent()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .onAppear {
            guard selectedID == nil, combinations.indices.contains(startIndex) else { return }
            selectedID = combinations[startIndex].id
        }
        .sheet(item: $rateSheetCombination) { combination in
            RateCombinationView(combination: combination, items: viewModel.resolveItems(for: combination))
        }
    }

    private func deleteCurrent() {
        guard let selectedID, let combination = combinations.first(where: { $0.id == selectedID }) else { return }
        // Checked before deleting, not after — `@Query`'s refresh isn't
        // guaranteed to have landed synchronously by the time this function
        // returns, so reading `combinations.count` post-delete could still
        // see the stale (pre-delete) count.
        let wasLastCombination = combinations.count <= 1
        viewModel.delete(combination)
        if wasLastCombination {
            dismiss()
        }
    }
}

private struct CombinationDetailPage: View {
    let combination: SavedCombination
    /// Keys `image` below — see `ClosetView.swift`'s matching comment on why
    /// a background-downloaded photo needs an explicit redraw trigger. Kept
    /// off the whole page (and off the parent `TabView`) deliberately, so a
    /// photo landing mid-browse doesn't reset `CombinationDetailView`'s
    /// `selectedID` scroll position.
    let photoRefreshTick: Int
    let onRate: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                image
                    .id(photoRefreshTick)
                    .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Text(combination.displayTitle)
                        .font(.headline)
                    Text(combination.savedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onRate()
                } label: {
                    Label("Rate this outfit", systemImage: "star.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
        }
    }

    @ViewBuilder
    private var image: some View {
        if let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: combination.imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .clipShape(VCRadius.shape(VCRadius.card))
                .vcShadow()
        } else {
            Label("Couldn't load this image", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}
