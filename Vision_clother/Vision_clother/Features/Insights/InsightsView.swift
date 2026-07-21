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
    case overview, style, trends, wardrobe, discover

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .style: return "Style"
        case .trends: return "Trends"
        case .wardrobe: return "Wardrobe"
        case .discover: return "Discover"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .style: return "paintpalette"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .wardrobe: return "tshirt"
        case .discover: return "sparkle.magnifyingglass"
        }
    }

    var description: String {
        switch self {
        case .overview: return "A quick snapshot of your closet and recent activity."
        case .style: return "The colors and patterns you actually gravitate toward, based on your closet and feedback."
        case .trends: return "How your color, category, and style preferences are shifting over time."
        case .wardrobe: return "How well you're using what you already own — worn vs. unworn, gaps, and duplicates."
        case .discover: return "Personalized recommendations, coming soon."
        }
    }
}

struct InsightsView: View {
    @State private var section: InsightsSection = .overview

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
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
                    .padding(.horizontal, VCSpacing.lg)
                    .padding(.top, 4)

                content
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
            comingSoon(section)
        }
    }

    private func comingSoon(_ section: InsightsSection) -> some View {
        ContentUnavailableView(
            "\(section.label) — Coming Soon",
            systemImage: section.systemImage,
            description: Text("This section is on the way in a future update.")
        )
        .navigationTitle(section.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    InsightsView()
        .modelContainer(
            for: [WardrobeItem.self, ItemRating.self, OutfitFeedback.self, WornLogEntry.self],
            inMemory: true
        )
}
