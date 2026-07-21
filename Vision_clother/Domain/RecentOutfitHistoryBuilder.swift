//
//  RecentOutfitHistoryBuilder.swift
//  Vision_clother
//
//  Anti-Repetition: turns raw `WornLogEntry` rows (already fetched/date-
//  bounded by the caller) plus their source `SavedCombination`s into the
//  bounded, LLM-ready text `Domain/StylistBrain.swift`'s OUTFIT ROTATION
//  section reads — the prompt-only half of the anti-repetition feature (the
//  permanent item-pair veto's `banPromptText` lives here too since both feed
//  the same prompt region and are always consumed together, but the two
//  concerns are otherwise independent — see
//  `Domain/OutfitRecommendationValidator.swift`'s `.bannedPair` for that
//  feature's deterministic half).
//
//  Pure, no I/O (Domain/CLAUDE.md) — mirrors `Domain/WardrobeCatalogBuilder.swift`'s
//  shape: bounded, logged, a pure function of already-fetched data.
//

import Foundation
import os

enum RecentOutfitHistoryBuilder {
    /// One recently-worn combination, bucketed by recency tier.
    struct RecentCombo {
        let itemIDs: Set<UUID>
        let labels: [String]
        let daysAgo: Int
    }

    struct Result {
        var hardAvoid: [RecentCombo] = []
        var softPenalize: [RecentCombo] = []

        static let empty = Result()

        var isEmpty: Bool { hardAvoid.isEmpty && softPenalize.isEmpty }
    }

    /// Joins `wornEntries` (already fetched by the caller, bounded to the
    /// `softPenalizeWindowDays` window) back to their `SavedCombination` for
    /// the item-set + labels, bucketed by recency tier. Multiple wears of
    /// the same combination in the window collapse to one entry — the
    /// prompt needs "was this worn recently," not a wear count — keeping
    /// whichever wear is most recent (smallest `daysAgo`).
    static func build(
        wornEntries: [WornLogEntry],
        combinationsByID: [UUID: SavedCombination],
        now: Date = .now
    ) -> Result {
        var bestDaysAgoByCombinationID: [UUID: Int] = [:]
        for entry in wornEntries {
            let daysAgo = max(0, Int(now.timeIntervalSince(entry.wornAt) / 86400))
            if let existing = bestDaysAgoByCombinationID[entry.savedCombinationID] {
                bestDaysAgoByCombinationID[entry.savedCombinationID] = min(existing, daysAgo)
            } else {
                bestDaysAgoByCombinationID[entry.savedCombinationID] = daysAgo
            }
        }

        var result = Result()
        for (combinationID, daysAgo) in bestDaysAgoByCombinationID {
            guard let combination = combinationsByID[combinationID] else { continue }
            let itemIDs = Set(combination.itemIDsBySlot.values).union(combination.supplementaryAccessoryItemIDs)
            guard !itemIDs.isEmpty else { continue }
            let labels = Slot.allCases.compactMap { combination.labelsBySlot[$0] } + combination.supplementaryAccessoryLabels
            let combo = RecentCombo(itemIDs: itemIDs, labels: labels, daysAgo: daysAgo)

            if daysAgo <= FashionKnowledgeConstants.Rotation.hardAvoidWindowDays {
                result.hardAvoid.append(combo)
            } else if daysAgo <= FashionKnowledgeConstants.Rotation.softPenalizeWindowDays {
                result.softPenalize.append(combo)
            }
        }

        MLLog.logger.notice("recentHistoryBuild: wornEntries=\(wornEntries.count) hardAvoid=\(result.hardAvoid.count) softPenalize=\(result.softPenalize.count)")
        return result
    }

    /// Bounded prompt text for `StylistBrain`'s user-content block — one
    /// line per combo, item ids (matching the catalog's own id space, so
    /// the LLM can cross-reference) plus sanitized labels as a
    /// human-readable aside.
    static func promptText(for result: Result) -> String {
        var lines: [String] = []
        for combo in result.hardAvoid.sorted(by: { $0.daysAgo < $1.daysAgo }) {
            lines.append("- [\(combo.daysAgo) day(s) ago, HARD AVOID] \(sanitizeForPrompt(combo.labels.joined(separator: " + "))): \(combo.itemIDs.map(\.uuidString).joined(separator: ", "))")
        }
        for combo in result.softPenalize.sorted(by: { $0.daysAgo < $1.daysAgo }) {
            lines.append("- [\(combo.daysAgo) day(s) ago, soft penalty] \(sanitizeForPrompt(combo.labels.joined(separator: " + "))): \(combo.itemIDs.map(\.uuidString).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Bounded prompt text for the permanent item-pair veto — see
    /// `Models/ItemPairBan.swift`. `catalog` is the same bounded array
    /// `Services/OutfitRecommendationService.swift`'s `encodeRequestBody`
    /// already has on hand (no separate `WardrobeItem` index available at
    /// that layer); labels are a human-readable aside built from each
    /// entry's slot/garment type, not authoritative. A ban whose item(s)
    /// have since left the catalog (or were never in this bounded slice) is
    /// skipped, since the LLM has no id to avoid either way.
    static func banPromptText(_ bans: [ItemPairBan], catalog: [CatalogEntry]) -> String {
        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        return bans.compactMap { ban -> String? in
            guard let entryA = entriesByID[ban.itemAID.uuidString], let entryB = entriesByID[ban.itemBID.uuidString] else { return nil }
            return "- \(sanitizeForPrompt(label(for: entryA))) (\(ban.itemAID.uuidString)) + \(sanitizeForPrompt(label(for: entryB))) (\(ban.itemBID.uuidString))"
        }.joined(separator: "\n")
    }

    private static func label(for entry: CatalogEntry) -> String {
        "\(entry.slot.rawValue) — \(entry.garmentSubtype ?? entry.colorCategory.rawValue)"
    }

    /// Item labels are free text (user-entered or vision-model-generated)
    /// interpolated directly into the prompt — strip newlines and
    /// prompt-structuring characters so a stray label can't distort the
    /// surrounding structure, same spirit as `WardrobeCatalogBuilder`'s
    /// `truncate(_:to:)` bound on `description`.
    private static func sanitizeForPrompt(_ label: String) -> String {
        label
            .components(separatedBy: .newlines).joined(separator: " ")
            .filter { !"[]{}:\"".contains($0) }
            .trimmingCharacters(in: .whitespaces)
    }
}
