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
    /// Quota visibility feature (`Data/UsageTracker.swift`) — live
    /// combinations caption near "Generate Preview".
    @Environment(UsageTracker.self) private var usageTracker

    @State private var viewModel: ManualPairingViewModel?
    /// Ticks once per "Generate Preview" tap and once per completed save —
    /// each drives its own critical-action haptic without firing on
    /// unrelated state changes.
    @State private var generateTick = 0
    @State private var didSaveTick = 0

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
            let repository = SyncingWardrobeRepository(modelContext: modelContext)
            viewModel = ManualPairingViewModel(
                repository: repository,
                validationService: ServiceFactory.makePersonPhotoValidationService(),
                tryOnService: ServiceFactory.makeTryOnRenderService(repository: repository),
                photoLibrarySaver: ServiceFactory.makePhotoLibrarySaver(),
                usageTracker: usageTracker
            )
        }
        .onChange(of: viewModel?.didSaveOutfit) { _, didSave in
            // Rating now happens exclusively from the Combinations tab — a
            // successful save just closes this screen.
            if didSave == true {
                didSaveTick += 1
                dismiss()
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: generateTick)
        .sensoryFeedback(.success, trigger: didSaveTick)
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
                .font(.largeTitle)
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
                            Button { onSelect(item) } label: {
                                PairingItemCell(item: item, isSelected: selected?.id == item.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    // MARK: - Generation

    @ViewBuilder
    private func generationSection(viewModel: ManualPairingViewModel) -> some View {
        switch viewModel.state {
        case .idle:
            combinationsQuotaCaption

            Button("Generate Preview") {
                viewModel.generatePreview()
                generateTick += 1
            }
            .buttonStyle(PrimaryButtonStyle())
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
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        Task { await viewModel.saveOutfit(liked: true) }
                    } label: {
                        Label("Like", systemImage: "hand.thumbsup")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.generatePreview() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    /// Quota visibility feature — "combinations" is the user-facing term
    /// for a try-on render (`Data/UsageTracker.swift`'s doc comment).
    @ViewBuilder
    private var combinationsQuotaCaption: some View {
        if usageTracker.combinationsRemaining <= 0 {
            Text(usageTracker.isAnonymousQuota
                 ? "Sign in to try this on."
                 : "You've used all your combinations this month. Resets next month.")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Text("\(usageTracker.combinationsRemaining) combination\(usageTracker.combinationsRemaining == 1 ? "" : "s") left this month")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    @State private var isPressed = false

    var body: some View {
        swatch
            .frame(width: 100, height: 100)
            .clipShape(VCRadius.shape(VCRadius.swatch))
            .overlay {
                VCRadius.shape(VCRadius.swatch)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .scaleEffect(isSelected ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    @ViewBuilder
    private var swatch: some View {
        CachedWardrobeImage(assetName: item.imageAssetName) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            VCRadius.shape(VCRadius.swatch)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ManualPairingView()
        .modelContainer(container)
        .environment(UsageTracker(
            repository: SyncingWardrobeRepository(modelContext: container.mainContext),
            syncService: MockWardrobeSyncService()
        ))
}
