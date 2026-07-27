//
//  OutfitChemistryView.swift
//  Vision_clother
//
//  Analytics & Insights — "Chemistry" sub-tab (Multi-Garment "Discover Your
//  Style"). The one Insights surface built on genuinely new signal: whole-look
//  color harmony, style coherence, and formality "rule-breaking" learned from
//  swiped full-outfit photos, rather than single-garment taste or closet
//  composition. Same shape as `TasteInsightsView` — reuses `AffinityBarRow`,
//  `InsightSourceCaption`, and `.premiumCard()`.
//

import SwiftData
import SwiftUI

struct OutfitChemistryView: View {
    @Environment(\.modelContext) private var modelContext
    // Recompute whenever the signals that feed the profile/combinations
    // change — same convention as `TasteInsightsView`.
    @Query private var combinationEvents: [SwipeCombinationEvent]
    @Query private var itemRatings: [ItemRating]
    @Query private var outfitFeedbacks: [OutfitFeedback]
    // Whole-look chemistry can only be learned from rated outfits, so this
    // tab also has to be able to *ask* for that feedback — the empty state
    // lists the user's own unrated saved outfits and opens
    // `RateCombinationView` on each, rather than telling them to go find the
    // Discover deck themselves.
    @Query(sort: \SavedCombination.savedAt, order: .reverse) private var savedCombinations: [SavedCombination]
    @Query private var inventory: [WardrobeItem]

    @State private var viewModel = OutfitChemistryViewModel()
    @State private var combinationToRate: SavedCombination?

    var body: some View {
        Group {
            if let snapshot = viewModel.snapshot {
                if snapshot.hasSignal {
                    content(snapshot)
                } else {
                    stillLearning
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Chemistry")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $combinationToRate) { combination in
            RateCombinationView(combination: combination, items: resolveItems(for: combination))
        }
        .task {
            recompute()
        }
        .onChange(of: combinationEvents.count) { recompute() }
        .onChange(of: itemRatings.count) { recompute() }
        .onChange(of: outfitFeedbacks.count) { recompute() }
    }

    /// Saved outfits that carry no whole-look chemistry yet — every one of
    /// them is a card this tab could be showing, so they're exactly what the
    /// prompt below asks the user to rate. A row that was rated through the
    /// swipe+comment flow but whose LLM chemistry inference failed still
    /// counts as pending, since it contributed nothing to the profile.
    private var combinationsAwaitingFeedback: [SavedCombination] {
        let ratedIDs = Set(
            outfitFeedbacks
                .filter { $0.swipeSentiment != nil && $0.inferredCombinationMetadata != nil }
                .map(\.outfitID)
        )
        return savedCombinations.filter { !ratedIDs.contains($0.id) }
    }

    private func resolveItems(for combination: SavedCombination) -> [WardrobeItem] {
        let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        return CombinationsViewModel.resolveItems(for: combination, itemsByID: itemsByID)
    }

    private func recompute() {
        let stockPhotoSnapshots = combinationEvents.map { event in
            RatedCombinationSnapshot(
                colorHarmony: event.colorHarmony,
                styleCoherenceTags: event.styleCoherenceTags,
                formalityConsistency: event.formalityConsistency,
                rationale: event.rationale,
                sentiment: event.sentiment,
                recordedAt: event.recordedAt,
                paletteArchetype: event.paletteArchetype,
                contrastLevel: event.contrastLevel,
                colorSandwiching: event.colorSandwiching,
                proportionRatio: event.proportionRatio,
                volumeBalance: event.volumeBalance,
                textureContrast: event.textureContrast,
                formalityBridge: event.formalityBridge
            )
        }
        // Swipe + Comment combination feedback (2026-07-27): owned-item
        // combinations the user swiped on surface here too, not just stock
        // photos from the Discover deck — unified with `stockPhotoSnapshots`
        // above via the same `RatedCombinationSnapshot` shape.
        let ownCombinationSnapshots = outfitFeedbacks.compactMap { feedback -> RatedCombinationSnapshot? in
            guard let sentiment = feedback.swipeSentiment, let chemistry = feedback.inferredCombinationMetadata else { return nil }
            return RatedCombinationSnapshot(
                colorHarmony: chemistry.colorHarmony,
                styleCoherenceTags: chemistry.styleCoherenceTags,
                formalityConsistency: chemistry.formalityConsistency,
                rationale: chemistry.rationale,
                sentiment: sentiment,
                recordedAt: feedback.recordedAt,
                paletteArchetype: chemistry.paletteArchetype,
                contrastLevel: chemistry.contrastLevel,
                colorSandwiching: chemistry.colorSandwiching,
                proportionRatio: chemistry.proportionRatio,
                volumeBalance: chemistry.volumeBalance,
                textureContrast: chemistry.textureContrast,
                formalityBridge: chemistry.formalityBridge
            )
        }
        viewModel.recompute(combinations: stockPhotoSnapshots + ownCombinationSnapshots, repository: SyncingWardrobeRepository(modelContext: modelContext))
    }

    private func content(_ snapshot: OutfitChemistrySnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VCSpacing.xxl) {
                if !snapshot.colorHarmonyRows.isEmpty {
                    dimensionCard(
                        title: "Color Harmony",
                        icon: "paintpalette.fill",
                        caption: "How the colors across your loved full outfits relate to one another.",
                        rows: snapshot.colorHarmonyRows
                    )
                }
                if !snapshot.styleCoherenceRows.isEmpty {
                    dimensionCard(
                        title: "Style Coherence",
                        icon: "sparkles",
                        caption: "The whole-look style identities your favorite outfits share.",
                        rows: snapshot.styleCoherenceRows
                    )
                }
                if !snapshot.paletteArchetypeRows.isEmpty {
                    dimensionCard(
                        title: "Palette Archetype",
                        icon: "circle.hexagongrid.fill",
                        caption: "The color relationships your loved outfits lean toward.",
                        rows: snapshot.paletteArchetypeRows
                    )
                }
                if !snapshot.contrastLevelRows.isEmpty {
                    dimensionCard(
                        title: "Contrast Level",
                        icon: "chart.bar.fill",
                        caption: "How much visual contrast your loved outfits carry overall.",
                        rows: snapshot.contrastLevelRows
                    )
                }
                if !snapshot.proportionRatioRows.isEmpty {
                    dimensionCard(
                        title: "Proportion",
                        icon: "square.split.2x1",
                        caption: "How your loved outfits balance visual weight top-to-bottom.",
                        rows: snapshot.proportionRatioRows
                    )
                }
                if !snapshot.volumeBalanceRows.isEmpty {
                    dimensionCard(
                        title: "Volume Balance",
                        icon: "square.stack.3d.up.fill",
                        caption: "The fit/volume relationship between pieces in your loved outfits.",
                        rows: snapshot.volumeBalanceRows
                    )
                }
                if !snapshot.textureContrastRows.isEmpty {
                    dimensionCard(
                        title: "Texture Contrast",
                        icon: "square.on.square",
                        caption: "How much your loved outfits mix contrasting surface textures.",
                        rows: snapshot.textureContrastRows
                    )
                }
                if !snapshot.formalityBridgeRows.isEmpty {
                    dimensionCard(
                        title: "Formality Bridge",
                        icon: "arrow.left.arrow.right",
                        caption: "Whether your loved outfits keep formality consistent or bridge it deliberately.",
                        rows: snapshot.formalityBridgeRows
                    )
                }
                ruleBreakingCard(snapshot)
                colorSandwichingCard(snapshot)
                if !snapshot.sampleRationales.isEmpty {
                    whyTheseWorkCard(snapshot)
                }
                if !combinationsAwaitingFeedback.isEmpty {
                    rateMoreCard
                }
            }
            .padding(VCSpacing.lg)
        }
    }

    /// Shown under real content: every dimension above sharpens with more
    /// rated outfits, so the tab keeps asking rather than going quiet once it
    /// has just enough signal to render.
    private var rateMoreCard: some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Label("Sharpen This", systemImage: "plus.circle.fill")
                .font(.headline)
            InsightSourceCaption(text: "\(combinationsAwaitingFeedback.count) saved outfit\(combinationsAwaitingFeedback.count == 1 ? "" : "s") you haven't reacted to yet")
            Text("Every outfit you swipe teaches this tab another read on what makes a combination work for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            outfitRatingRows(Array(combinationsAwaitingFeedback.prefix(Self.maxPromptedOutfits)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    /// At most this many outfits offered at once — the prompt is a nudge, not
    /// a work queue.
    private static let maxPromptedOutfits = 5

    /// One tappable row per outfit, opening the same swipe+comment flow
    /// `CombinationDetailView`'s "Rate this outfit" does.
    private func outfitRatingRows(_ combinations: [SavedCombination]) -> some View {
        VStack(spacing: VCSpacing.xs) {
            ForEach(combinations) { combination in
                Button {
                    combinationToRate = combination
                } label: {
                    HStack(spacing: VCSpacing.sm) {
                        outfitThumbnail(combination)
                        Text(combination.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: VCSpacing.sm)
                        Image(systemName: "hand.draw")
                            .font(.subheadline)
                            .foregroundStyle(VCAccentColor.brand)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, VCSpacing.xs)
    }

    @ViewBuilder
    private func outfitThumbnail(_ combination: SavedCombination) -> some View {
        let size = CGSize(width: 44, height: 44)
        if combination.hasRenderedImage {
            CachedWardrobeImage(assetName: combination.imageAssetName, thumbnailSize: size) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(VCRadius.shape(VCRadius.swatch))
            } placeholder: {
                slotSwatches(combination)
            }
        } else {
            slotSwatches(combination)
        }
    }

    /// Fallback for an outfit with no render yet — the item colors it's made
    /// of, reusing the same `SwatchCluster` the Taste tab uses.
    private func slotSwatches(_ combination: SavedCombination) -> some View {
        let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let hexes = CombinationsViewModel.resolveItems(for: combination, itemsByID: itemsByID)
            .prefix(4)
            .map(\.colorProfile.primaryHex)
        return SwatchCluster(hexes: Array(hexes))
            .frame(width: 44, alignment: .leading)
    }

    private func dimensionCard(title: String, icon: String, caption: String, rows: [OutfitChemistrySnapshot.Row]) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            InsightSourceCaption(text: "50% is neutral — higher means outfits like this work for you")
            VStack(spacing: VCSpacing.sm) {
                ForEach(rows) { row in
                    AffinityBarRow(label: row.label, affinity: row.affinity)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func ruleBreakingCard(_ snapshot: OutfitChemistrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: VCSpacing.sm) {
                Label("Rule-Breaking", systemImage: "bolt.fill")
                    .font(.headline)
                Spacer()
                Text("\(Int((snapshot.intentionalContrastShare * 100).rounded()))%")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(VCAccentColor.brand)
            }
            InsightSourceCaption(text: "Share of your loved/liked outfits that deliberately mix formality levels")
            Text(ruleBreakingSummary(snapshot.intentionalContrastShare))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func ruleBreakingSummary(_ share: Double) -> String {
        let pct = Int((share * 100).rounded())
        if pct >= 40 {
            return "You often mix dressy and casual pieces on purpose — and it works for you."
        } else if pct > 0 {
            return "You occasionally break the formality-matching rule, and it pays off."
        } else {
            return "Your loved outfits tend to keep formality consistent across every piece."
        }
    }

    private func colorSandwichingCard(_ snapshot: OutfitChemistrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: VCSpacing.sm) {
                Label("Color Sandwiching", systemImage: "square.3.layers.3d.down.right")
                    .font(.headline)
                Spacer()
                Text("\(Int((snapshot.colorSandwichingShare * 100).rounded()))%")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(VCAccentColor.brand)
            }
            InsightSourceCaption(text: "Share of your loved/liked outfits where the top/outerwear color is echoed by the footwear over a contrasting middle layer")
            Text(colorSandwichingSummary(snapshot.colorSandwichingShare))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func colorSandwichingSummary(_ share: Double) -> String {
        let pct = Int((share * 100).rounded())
        if pct >= 40 {
            return "You lean on this bookending trick often — it's a signature move for you."
        } else if pct > 0 {
            return "You occasionally bookend an outfit with a matching top/shoe color."
        } else {
            return "Your loved outfits don't tend to rely on this particular color trick."
        }
    }

    private func whyTheseWorkCard(_ snapshot: OutfitChemistrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: VCSpacing.sm) {
            Label("Why These Work", systemImage: "quote.bubble.fill")
                .font(.headline)
            InsightSourceCaption(text: "The AI's read on your most-loved outfit combinations")
            VStack(alignment: .leading, spacing: VCSpacing.xs) {
                ForEach(Array(snapshot.sampleRationales.enumerated()), id: \.offset) { _, rationale in
                    Text("\u{201C}\(rationale)\u{201D}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    /// Chemistry is the one Insights surface with no closet-composition
    /// fallback: it can only describe whole outfits the user has actually
    /// reacted to. So the empty state does the asking — it lists their own
    /// saved outfits and opens the swipe+comment flow on each, instead of
    /// pointing at a different tab and leaving.
    @ViewBuilder
    private var stillLearning: some View {
        let pending = combinationsAwaitingFeedback
        if pending.isEmpty {
            ContentUnavailableView {
                Label("Still Learning Your Chemistry", systemImage: "flame")
            } description: {
                Text("Save an outfit — from Daily Assistant or Pairing — then react to it, and this tab will read the color harmony, proportion, and rule-breaking behind what you like.\n\nSwiping full-outfit looks in the Discover deck teaches it too.")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: VCSpacing.lg) {
                    VStack(alignment: .leading, spacing: VCSpacing.sm) {
                        Label("Tell Me About These Outfits", systemImage: "flame")
                            .font(.headline)
                        Text("Chemistry reads whole looks, not single garments — so it needs your reaction to outfits you've actually seen. React to a few of these and this tab fills in with your color harmony, proportion, and rule-breaking patterns.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        outfitRatingRows(Array(pending.prefix(Self.maxPromptedOutfits)))
                        if pending.count > Self.maxPromptedOutfits {
                            Text("\(pending.count - Self.maxPromptedOutfits) more waiting in Combinations.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, VCSpacing.xs)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .premiumCard()

                    InsightSourceCaption(text: "Swiping full-outfit looks in the Discover deck teaches this tab too")
                }
                .padding(VCSpacing.lg)
            }
        }
    }
}

#Preview {
    NavigationStack {
        OutfitChemistryView()
    }
    .modelContainer(
        for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self, SwipeCombinationEvent.self],
        inMemory: true
    )
}
