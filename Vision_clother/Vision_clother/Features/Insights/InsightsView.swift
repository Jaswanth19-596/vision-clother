//
//  InsightsView.swift
//  Vision_clother
//
//  Tab 5: Analytics & Insights. Top segmented control switches between the
//  five sub-tabs the Phase 1 plan mapped from the spec (renaming its
//  duplicate fifth "Insights" sub-tab to "Discover" — see the plan's
//  Navigation section). Only Overview is functional this phase; the rest
//  are placeholders so the nav shell is complete for the phases that build
//  them (Style: Phase 5/10, Trends: Phase 7, Wardrobe: Phase 8/9, Discover:
//  alongside those).
//

import SwiftData
import SwiftUI

private enum InsightsSection: String, CaseIterable, Identifiable {
    case overview, style, trends, wardrobe, discover, chemistry

    var id: String { rawValue }

    /// Position in the segmented control — drives which side the incoming
    /// sub-tab slides in from (`VCTransition.lateral`), so the content moves
    /// the same direction the user's tap did.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .style: return "Style"
        case .trends: return "Trends"
        case .wardrobe: return "Wardrobe"
        case .discover: return "Taste"
        case .chemistry: return "Chemistry"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .style: return "paintpalette"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .wardrobe: return "tshirt"
        case .discover: return "heart.text.square"
        case .chemistry: return "flame.fill"
        }
    }

    var description: String {
        switch self {
        case .overview: return "A quick snapshot of your closet and recent activity."
        case .style: return "The colors and patterns you actually gravitate toward, based on your closet and feedback."
        case .trends: return "How your color, category, and style preferences are shifting over time."
        case .wardrobe: return "How well you're using what you already own — worn vs. unworn, gaps, and duplicates."
        case .discover: return "The colors, fits, and materials you gravitate toward — and where your closet matches or misses what you love."
        case .chemistry: return "What your loved full-outfit swipes reveal about color harmony, style coherence, and rule-breaking combos."
        }
    }
}

struct InsightsView: View {
    @State private var section: InsightsSection = .overview
    /// Which way the last section change moved, so the incoming sub-tab
    /// enters from the side the user tapped toward. Set synchronously in
    /// `sectionBinding` — an `.onChange` would resolve a render too late,
    /// after the transition has already been committed with the stale value.
    @State private var isForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the section change through an explicit `withAnimation` rather
    /// than a value-keyed `.animation` on `content`'s `Group`. The previous
    /// arrangement (`.transition(.opacity)` + `.animation(contentFade, value:
    /// section)` both on the `Group`) produced no visible motion on device;
    /// `withAnimation` at the mutation site removes any question about whether
    /// the transition has an animation in scope when the branch swaps. The
    /// transition itself also now carries lateral movement instead of opacity
    /// alone, which between two sub-views sharing a background read as an
    /// instant cut at any duration.
    private var sectionBinding: Binding<InsightsSection> {
        Binding(
            get: { section },
            set: { newValue in
                guard newValue != section else { return }
                isForward = newValue.index > section.index
                withAnimation(vcMotion(VCMotion.standard, reduceMotion: reduceMotion)) {
                    section = newValue
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: sectionBinding) {
                    ForEach(InsightsSection.allCases) { section in
                        Text(section.label).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, VCSpacing.lg)
                .padding(.top, VCSpacing.sm)

                Text(section.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .padding(.horizontal, VCSpacing.lg)
                    .padding(.top, 4)

                content
                    // The lateral slide moves a full-width sub-view; without
                    // this the outgoing/incoming halves bleed past the screen
                    // edge and briefly widen the layout.
                    .clipped()
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    JobQueueBadgeButton()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch section {
            case .overview:
                OverviewView()
            case .style:
                StyleView()
            case .trends:
                TrendsView()
            case .wardrobe:
                WardrobeInsightsView()
            case .discover:
                TasteInsightsView()
            case .chemistry:
                OutfitChemistryView()
            }
        }
        .transition(VCTransition.lateral(forward: isForward))
    }
}

#Preview {
    InsightsView()
        .modelContainer(
            for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self, WornLogEntry.self, SwipeCombinationEvent.self],
            inMemory: true
        )
}
