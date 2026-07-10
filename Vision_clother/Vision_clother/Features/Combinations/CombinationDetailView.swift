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
    @State private var isRateSheetPresented = false

    var body: some View {
        TabView(selection: $selectedID) {
            ForEach(viewModel.combinations, id: \.id) { combination in
                CombinationDetailPage(combination: combination, onRate: { isRateSheetPresented = true })
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
        .sheet(isPresented: $isRateSheetPresented) {
            if let selectedCombination {
                RateCombinationView(combination: selectedCombination, items: viewModel.resolveItems(for: selectedCombination))
            }
        }
    }

    private var selectedCombination: SavedCombination? {
        viewModel.combinations.first { $0.id == selectedID }
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
                    Text("\(combination.topLabel) + \(combination.bottomLabel)")
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
