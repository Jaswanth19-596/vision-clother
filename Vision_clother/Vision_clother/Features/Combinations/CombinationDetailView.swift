//
//  CombinationDetailView.swift
//  Vision_clother
//
//  Full-screen page view over CombinationsViewModel.combinations, opened at
//  the tapped row's index. Paging lets the user swipe to adjacent saved
//  combinations without going back to the list; toolbar Delete removes
//  whichever page is currently showing.
//

import SwiftUI

struct CombinationDetailView: View {
    let viewModel: CombinationsViewModel
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var rateSheetCombination: SavedCombination?

    var body: some View {
        TabView(selection: $selectedID) {
            ForEach(viewModel.combinations, id: \.id) { combination in
                CombinationDetailPage(combination: combination, onRate: { rateSheetCombination = combination })
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
            guard selectedID == nil, viewModel.combinations.indices.contains(startIndex) else { return }
            selectedID = viewModel.combinations[startIndex].id
        }
        .sheet(item: $rateSheetCombination) { combination in
            RateCombinationView(combination: combination, items: viewModel.resolveItems(for: combination))
        }
    }

    private func deleteCurrent() {
        guard let selectedID, let combination = viewModel.combinations.first(where: { $0.id == selectedID }) else { return }
        viewModel.delete(combination)
        if viewModel.combinations.isEmpty {
            dismiss()
        }
    }
}

private struct CombinationDetailPage: View {
    let combination: SavedCombination
    let onRate: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                image
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
                .buttonStyle(.bordered)
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
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            Label("Couldn't load this image", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}
