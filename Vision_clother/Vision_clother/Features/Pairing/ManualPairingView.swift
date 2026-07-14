//
//  ManualPairingView.swift
//  Vision_clother
//
//  Sheet content for Manual Outfit Pairing with AI Virtual Try-On. Presented
//  from ClosetView. Two sections once a portrait exists: the top/bottom
//  pickers and the state-driven generation result — mirrors AddItemView's
//  capture-source-picker / progress-state / failed-with-retry shape for
//  consistency with the rest of the ingestion-flavored UI in this app.
//
//  The user's own photo is captured/managed exclusively on the Profile tab
//  (Features/Profile/ProfileView.swift) — this view only reads its presence
//  via `ManualPairingViewModel.hasPortrait` and prompts the user there if
//  none exists yet, rather than capturing it inline.
//

import SwiftData
import SwiftUI

struct ManualPairingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ManualPairingViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Try On")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            let repository = SwiftDataWardrobeRepository(modelContext: modelContext)
            viewModel = ManualPairingViewModel(
                repository: repository,
                validationService: ServiceFactory.makePersonPhotoValidationService(),
                tryOnService: ServiceFactory.makeTryOnRenderService(repository: repository),
                photoLibrarySaver: ServiceFactory.makePhotoLibrarySaver()
            )
        }
        .onChange(of: viewModel?.didSaveOutfit) { _, didSave in
            // Rating now happens exclusively from the Combinations tab — a
            // successful save just closes this screen.
            if didSave == true { dismiss() }
        }
    }

    @ViewBuilder
    private func content(viewModel: ManualPairingViewModel) -> some View {
        if !viewModel.hasPortrait {
            missingPortraitPrompt
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    itemPicker(title: "Shirt", items: viewModel.availableTops, selected: viewModel.selectedTop) {
                        viewModel.selectTop($0)
                    }
                    itemPicker(title: "Pants", items: viewModel.availableBottoms, selected: viewModel.selectedBottom) {
                        viewModel.selectBottom($0)
                    }
                    generationSection(viewModel: viewModel)
                }
                .padding()
            }
        }
    }

    private var missingPortraitPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Add a photo on your Profile tab to try on outfits.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Your Profile photo is reused here so you only ever set it up once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Item pickers

    private func itemPicker(
        title: String,
        items: [WardrobeItem],
        selected: WardrobeItem?,
        onSelect: @escaping (WardrobeItem) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)

            if items.isEmpty {
                Text("No \(title.lowercased()) in your closet yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items, id: \.id) { item in
                            PairingItemCell(item: item, isSelected: selected?.id == item.id)
                                .onTapGesture { onSelect(item) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Generation

    @ViewBuilder
    private func generationSection(viewModel: ManualPairingViewModel) -> some View {
        switch viewModel.state {
        case .idle:
            Button("Generate Preview") {
                viewModel.generatePreview()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(!viewModel.canGeneratePreview)

        case .validatingPhoto:
            progress(viewModel: viewModel, label: "Checking your photo…")

        case .preparingImages:
            progress(viewModel: viewModel, label: "Preparing images…")

        case .generatingPreview(let stage):
            progress(viewModel: viewModel, label: stage.label)

        case .success(let imageURL):
            VStack(spacing: 16) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Label("Couldn't load the preview", systemImage: "photo.badge.exclamationmark")
                    default:
                        ProgressView()
                    }
                }
                .frame(maxHeight: 400)

                Text("Did you like this outfit?").font(.headline)
                HStack {
                    Button {
                        Task { await viewModel.saveOutfit(liked: false) }
                    } label: {
                        Label("Dislike", systemImage: "hand.thumbsdown")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await viewModel.saveOutfit(liked: true) }
                    } label: {
                        Label("Like", systemImage: "hand.thumbsup")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.generatePreview() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func progress(viewModel: ManualPairingViewModel, label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView(label)
            Button("Cancel", role: .cancel) { viewModel.cancelGeneration() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }
}

private struct PairingItemCell: View {
    let item: WardrobeItem
    let isSelected: Bool

    var body: some View {
        swatch
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
    }

    @ViewBuilder
    private var swatch: some View {
        if let imageAssetName = item.imageAssetName,
           let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
        }
    }
}

#Preview {
    ManualPairingView()
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self],
            inMemory: true
        )
}
