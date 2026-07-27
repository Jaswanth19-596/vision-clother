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

    @State private var viewModel = OutfitChemistryViewModel()

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
        .task {
            recompute()
        }
        .onChange(of: combinationEvents.count) { recompute() }
        .onChange(of: itemRatings.count) { recompute() }
        .onChange(of: outfitFeedbacks.count) { recompute() }
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
            }
            .padding(VCSpacing.lg)
        }
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

    private var stillLearning: some View {
        ContentUnavailableView {
            Label("Still Learning Your Chemistry", systemImage: "flame")
        } description: {
            Text("Swipe on a few full-outfit looks in the Discover deck — color harmony, style coherence, and rule-breaking combos will show up here.")
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
