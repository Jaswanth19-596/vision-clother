//
//  CombinationDetailView.swift
//  Vision_clother
//
//  Full-screen page view over the ordered id list `CombinationsView` handed
//  it (whichever of its two segments — "Generated" or "Worn" — the tapped
//  row came from), opened at that row's index. Paging lets the user swipe to
//  adjacent combinations within that same segment without going back to the
//  list; toolbar Delete removes whichever page is currently showing.
//

import SwiftData
import SwiftUI

struct CombinationDetailView: View {
    let viewModel: CombinationsViewModel
    /// The exact set + order of ids `CombinationsView` was showing in the
    /// segment the user tapped from, snapshotted at open time — not
    /// re-derived here, so paging never crosses from "Worn" into a
    /// "Generated"-only outfit or vice versa mid-browse.
    let orderedIDs: [UUID]
    let startIndex: Int

    /// Own live query rather than reading `viewModel.combinations` — this
    /// view can stay open while a background pull inserts/deletes rows out
    /// from under it (`Data/WardrobeSyncCoordinator.swift`); a `@Query`
    /// re-resolves automatically instead of paging through a stale/detached
    /// snapshot. `combinations` below reorders/filters this to `orderedIDs`
    /// so deletions still drop out live while the segment's own order (e.g.
    /// "Worn"'s most-recently-worn-first, which isn't `savedAt` order) is
    /// preserved.
    @Query(CombinationsView.recentCombinationsDescriptor) private var allCombinations: [SavedCombination]
    /// Photo-refresh reactivity — see `ClosetView.swift`'s matching comment.
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var rateSheetCombination: SavedCombination?
    @State private var banSheetCombination: SavedCombination?

    private var combinations: [SavedCombination] {
        let byID = Dictionary(uniqueKeysWithValues: allCombinations.map { ($0.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    var body: some View {
        TabView(selection: $selectedID) {
            ForEach(combinations, id: \.id) { combination in
                CombinationDetailPage(
                    combination: combination,
                    resolvedItems: viewModel.resolveItems(for: combination),
                    photoRefreshTick: syncCoordinator.photoRefreshTick,
                    generationState: viewModel.generationState(for: combination),
                    onRate: { rateSheetCombination = combination },
                    onBanPair: { banSheetCombination = combination },
                    onGenerateImage: { await viewModel.generateImage(for: combination) },
                    onWearToday: { viewModel.logWorn(combination) }
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
        .sheet(item: $banSheetCombination) { combination in
            BanPairView(items: viewModel.resolveItems(for: combination)) { itemA, itemB in
                viewModel.banPair(itemA, itemB)
            }
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
    /// Resolved via `CombinationsViewModel.resolveItems(for:)` — feeds the
    /// pre-render flatlay (`itemFlatlay` below) when this combination has no
    /// generated image yet, same items `RateCombinationView`'s picker uses.
    let resolvedItems: [WardrobeItem]
    /// Keys `image` below — see `ClosetView.swift`'s matching comment on why
    /// a background-downloaded photo needs an explicit redraw trigger. Kept
    /// off the whole page (and off the parent `TabView`) deliberately, so a
    /// photo landing mid-browse doesn't reset `CombinationDetailView`'s
    /// `selectedID` scroll position.
    let photoRefreshTick: Int
    /// Anti-Repetition's "Generate Image" follow-up to a placeholder
    /// combination (`SavedCombination.hasRenderedImage == false`) —
    /// `CombinationsViewModel.generateImage(for:)`'s in-flight state for
    /// this exact combination.
    let generationState: TryOnState
    let onRate: () -> Void
    let onBanPair: () -> Void
    let onGenerateImage: () async -> Void
    /// Same `CombinationsViewModel.logWorn` the list's leading swipe action
    /// (`CombinationsView.swift`) and the post-generation sheet
    /// (`TryOnResultView.swift`'s "Wear This Today") both already call — this
    /// is the third entry point onto the same "Worn" segment membership, for
    /// a combination the user is looking at full-screen after the fact
    /// rather than right after generating it or browsing the list.
    let onWearToday: () -> Void

    @State private var detailItem: WardrobeItem?
    /// Per-page lock, same convention as `TryOnResultView.didMarkWorn` — logging
    /// twice from one screening isn't useful, even though `logWorn` itself
    /// tolerates repeat calls (see its doc comment).
    @State private var didLogWornThisVisit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                image
                    .id(photoRefreshTick)
                    .frame(maxWidth: .infinity)

                if !combination.hasRenderedImage {
                    generateImageSection
                }

                VStack(spacing: 4) {
                    Text(combination.displayTitle)
                        .font(.headline)
                    Text(combination.savedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onWearToday()
                    didLogWornThisVisit = true
                } label: {
                    Label(
                        didLogWornThisVisit ? "Marked Worn Today" : "Wearing This Today",
                        systemImage: didLogWornThisVisit ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(didLogWornThisVisit)

                Button {
                    onRate()
                } label: {
                    Label("Rate this outfit", systemImage: "star.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    onBanPair()
                } label: {
                    Label("Never recommend these together", systemImage: "nosign")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding()
        }
        .sheet(item: $detailItem) { item in
            ItemDetailView(items: resolvedItems, selectedItemID: item.id)
        }
    }

    @ViewBuilder
    private var image: some View {
        if combination.hasRenderedImage {
            CachedWardrobeImage(assetName: combination.imageAssetName) { image in
                ZoomableImageContainer {
                    image
                        .resizable()
                        .scaledToFit()
                }
                .clipShape(VCRadius.shape(VCRadius.card))
                .vcShadow()
            } placeholder: {
                Label("Couldn't load this image", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        } else {
            // No generated render yet (Anti-Repetition's "Wearing This
            // Today" quick action saves before any image exists) — show the
            // same per-slot flatlay `OutfitCardView` shows for a fresh
            // recommendation, rather than a bare "no preview" placeholder,
            // so this reads as the outfit itself, not as broken/missing.
            itemFlatlay
        }
    }

    private var itemFlatlay: some View {
        VStack(spacing: 8) {
            ForEach(resolvedItems) { item in
                HStack {
                    thumbnail(for: item)

                    VStack(alignment: .leading) {
                        Text(item.slot.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.displayLabel)
                            .font(.subheadline)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !item.isGhostElement else { return }
                    detailItem = item
                }
            }
        }
        .premiumCard(radius: VCRadius.prominent, material: .regularMaterial)
    }

    /// Same rendering rule `OutfitCardView.thumbnail(for:)` uses: an ingested
    /// item's real isolated photo, or a flat color swatch (Ghost Elements
    /// have no photo).
    @ViewBuilder
    private func thumbnail(for item: WardrobeItem) -> some View {
        CachedWardrobeImage(assetName: item.imageAssetName) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(VCRadius.shape(VCRadius.swatch))
        } placeholder: {
            VCRadius.shape(VCRadius.swatch)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
                .frame(width: 44, height: 44)
                .overlay {
                    if item.isGhostElement {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.white)
                    }
                }
        }
    }

    @ViewBuilder
    private var generateImageSection: some View {
        switch generationState {
        case .idle, .failed:
            VStack(spacing: 8) {
                if case .failed(let error) = generationState {
                    Text(error.errorDescription ?? "Couldn't generate a preview.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await onGenerateImage() }
                } label: {
                    Label("Generate Image", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        case .submitting(let stage), .polling(let stage, _):
            ProgressView(stage.label)
                .frame(maxWidth: .infinity)
        case .succeeded:
            // `@Query` re-resolves `combination.imageAssetName` the instant
            // `updateCombinationImage` saves — this branch is only ever
            // visible for the brief window before that redraw lands.
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}

/// Anti-Repetition — authoring a permanent "never recommend these two
/// together" veto (`CombinationsViewModel.banPair(_:_:)`), scoped to items
/// within one already-saved outfit rather than a free-form whole-closet
/// picker: it reuses this combination's already-resolved items with no new
/// search/filter chrome, and matches how this need actually arises —
/// reacting to a specific pairing in front of you, not browsing the closet
/// in the abstract.
private struct BanPairView: View {
    let items: [WardrobeItem]
    let onBan: (WardrobeItem, WardrobeItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var didBan = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        Button {
                            toggle(item)
                        } label: {
                            HStack {
                                Text(item.displayLabel)
                                Spacer()
                                if selectedItemIDs.contains(item.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Pick exactly two items to never recommend together")
                } footer: {
                    Text("This is permanent — the stylist will never suggest these two items in the same outfit again.")
                }
            }
            .navigationTitle("Ban a Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if didBan {
                        Label("Banned", systemImage: "checkmark")
                    } else {
                        Button("Ban") {
                            guard selectedItemIDs.count == 2 else { return }
                            let selected = items.filter { selectedItemIDs.contains($0.id) }
                            guard selected.count == 2 else { return }
                            onBan(selected[0], selected[1])
                            didBan = true
                            dismiss()
                        }
                        .disabled(selectedItemIDs.count != 2)
                    }
                }
            }
        }
    }

    private func toggle(_ item: WardrobeItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else if selectedItemIDs.count < 2 {
            selectedItemIDs.insert(item.id)
        }
    }
}
