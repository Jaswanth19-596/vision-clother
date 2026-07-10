//
//  AnalyticsView.swift
//  Vision_clother
//
//  Tab 3: Style Analytics & Feedback Dashboard (PRD.md §4). Backed by real
//  SwiftData feedback queries from day one (not mocked) — persistence is
//  already in place per CLAUDE.md guardrail #3.
//

import SwiftUI
import SwiftData

struct AnalyticsView: View {
    @Query private var items: [WardrobeItem]
    @Query private var pairFeedbacks: [PairFeedback]
    @Query private var outfitFeedbacks: [OutfitFeedback]
    @Query private var itemRatings: [ItemRating]
    @Query private var styleProfiles: [UserStyleProfile]

    /// Single-row profile (PRD §3.8) — `Data/WardrobeRepository.swift`'s
    /// `saveUserProfile` guarantees at most one row exists.
    private var styleProfile: UserStyleProfile? { styleProfiles.first }

    private var itemsByID: [UUID: WardrobeItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    /// Item Rating & Preference Learning: the same attribute-affinity model
    /// `Domain/OutfitRecommendationEngine.swift` uses to bias recommendations
    /// (`Domain/AttributePreferenceProfile.swift`), surfaced here as a
    /// read-only "Your Taste" summary.
    private var attributeProfile: AttributePreferenceProfile {
        let ratedAttributes: [RatedAttributes] = itemRatings.compactMap { rating in
            guard let item = itemsByID[rating.itemID] else { return nil }
            return RatedAttributes(
                value: rating.normalizedValue,
                colorVibe: item.colorProfile.category,
                pattern: item.pattern,
                formalityBand: Int(item.formalityScore.rounded())
            )
        }
        return AttributePreferenceProfile.build(from: ratedAttributes)
    }

    /// Top-affinity color vibes, patterns, and formality bands — only
    /// attributes with at least one rating are shown (a bare 0.5 default
    /// means "no data yet", not "neutral taste").
    private var topColorVibes: [(label: String, affinity: Double)] {
        attributeProfile.colorVibeAffinity
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { ($0.key.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, $0.value) }
    }

    private var topPatterns: [(label: String, affinity: Double)] {
        attributeProfile.patternAffinity
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { ($0.key.rawValue.capitalized, $0.value) }
    }

    private var topFormalityBands: [(label: String, affinity: Double)] {
        attributeProfile.formalityAffinity
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { (formalityBandLabel($0.key), $0.value) }
    }

    private func formalityBandLabel(_ band: Int) -> String {
        switch band {
        case ..<2: return "Casual"
        case 2...3: return "Smart-Casual"
        default: return "Formal"
        }
    }

    /// Highest-ranking individual item pairs (PRD §4, Tab 3) — grouped from
    /// the raw pair-level feedback log (PRD §3.6) by liked-ratio descending.
    private var topPairs: [(itemA: WardrobeItem, itemB: WardrobeItem, likeRatio: Double, count: Int)] {
        var grouped: [PairKey: (likes: Int, total: Int)] = [:]
        for feedback in pairFeedbacks {
            let key = PairKey(feedback.itemAID, feedback.itemBID)
            var entry = grouped[key] ?? (likes: 0, total: 0)
            entry.total += 1
            if feedback.likedTogether { entry.likes += 1 }
            grouped[key] = entry
        }
        return grouped.compactMap { key, value in
            guard let itemA = itemsByID[key.a], let itemB = itemsByID[key.b] else { return nil }
            return (itemA, itemB, Double(value.likes) / Double(value.total), value.total)
        }
        .sorted { $0.likeRatio > $1.likeRatio }
    }

    /// Total closet formality balance (PRD §4, Tab 3).
    private var formalityBuckets: [(label: String, count: Int)] {
        let buckets: [(label: String, range: ClosedRange<Double>)] = [
            ("Casual", 1.0...2.0),
            ("Smart-Casual", 2.0...3.5),
            ("Formal", 3.5...5.0),
        ]
        return buckets.map { bucket in
            (bucket.label, items.filter { bucket.range.contains($0.formalityScore) }.count)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Style Profile") {
                    if let styleProfile {
                        HStack {
                            Text("Undertone")
                            Spacer()
                            Text(styleProfile.undertone.rawValue.capitalized)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Body Type")
                            Spacer()
                            Text(styleProfile.bodyType)
                                .foregroundStyle(.secondary)
                        }
                        if !styleProfile.styleKeywords.isEmpty {
                            HStack {
                                Text("Style")
                                Spacer()
                                Text(styleProfile.styleKeywords.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    } else {
                        Text("Add a portrait photo from Manual Outfit Pairing to derive your personal color and style profile.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Your Taste") {
                    if itemRatings.isEmpty {
                        Text("No item ratings yet — rate items from your closet or after a try-on to see your learned style preferences here.")
                            .foregroundStyle(.secondary)
                    } else {
                        tasteRow(title: "Favorite Colors", entries: topColorVibes)
                        tasteRow(title: "Favorite Patterns", entries: topPatterns)
                        tasteRow(title: "Favorite Formality", entries: topFormalityBands)
                    }
                }

                Section("Top Pairs") {
                    if topPairs.isEmpty {
                        Text("No pair feedback yet — like or dislike outfit pairings from Daily Assistant to see your best combinations here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(topPairs.prefix(5), id: \.itemA.id) { pair in
                            HStack {
                                Text("\(pair.itemA.pattern.rawValue.capitalized) + \(pair.itemB.pattern.rawValue.capitalized)")
                                Spacer()
                                Text("\(Int(pair.likeRatio * 100))% (\(pair.count))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Closet Formality Balance") {
                    ForEach(formalityBuckets, id: \.label) { bucket in
                        HStack {
                            Text(bucket.label)
                            Spacer()
                            Text("\(bucket.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Look History") {
                    Text("\(outfitFeedbacks.count) outfits rated so far.")
                        .foregroundStyle(.secondary)
                    // A historical calendar view (PRD §4) is a later
                    // iteration — the feedback log above is the seed data
                    // it will render from.
                }
            }
            .navigationTitle("Style Analytics")
        }
    }

    @ViewBuilder
    private func tasteRow(title: String, entries: [(label: String, affinity: Double)]) -> some View {
        if !entries.isEmpty {
            HStack {
                Text(title)
                Spacer()
                Text(entries.map { "\($0.label) (\(Int($0.affinity * 100))%)" }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

#Preview {
    AnalyticsView()
        .modelContainer(
            for: [
                WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self,
                SavedCombination.self, ItemRating.self, UserStyleProfile.self,
            ],
            inMemory: true
        )
}
