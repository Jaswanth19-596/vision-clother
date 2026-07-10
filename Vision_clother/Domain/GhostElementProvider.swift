//
//  GhostElementProvider.swift
//  Vision_clother
//
//  Virtual Capsule Injection (PRD.md §3.2): if a slot has zero real items,
//  inject a default semi-transparent "Ghost Element" so the recommendation
//  engine and Closet grid never see an empty slot. Ghost elements are scored
//  identically to real items (see PairCompatibilityScoring.swift) — this
//  file only decides *what* the placeholder looks like, not how it scores.
//

import Foundation

enum GhostElementProvider {
    /// One reasonable default garment per slot, per PRD.md §3.2's examples
    /// (standard white tee, tailored black jeans, casual white sneakers).
    /// Outerwear isn't given an explicit example in the PRD, so a neutral
    /// lightweight jacket is used to keep the four slots symmetric.
    static func defaultItem(for slot: Slot) -> WardrobeItem {
        switch slot {
        case .top:
            return WardrobeItem(
                slot: .top,
                formalityScore: 2.0,
                colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
                pattern: .solid,
                seasonality: Season.allCases,
                fabricWeight: .light,
                imageAssetName: "ghost_white_tee",
                isGhostElement: true
            )
        case .bottom:
            return WardrobeItem(
                slot: .bottom,
                formalityScore: 2.5,
                colorProfile: ColorProfile(primaryHex: "#1B1B1B", secondaryHex: nil, category: .neutral),
                pattern: .solid,
                seasonality: Season.allCases,
                fabricWeight: .medium,
                imageAssetName: "ghost_black_jeans",
                isGhostElement: true
            )
        case .footwear:
            return WardrobeItem(
                slot: .footwear,
                formalityScore: 2.0,
                colorProfile: ColorProfile(primaryHex: "#F5F5F0", secondaryHex: nil, category: .neutral),
                pattern: .solid,
                seasonality: Season.allCases,
                fabricWeight: .medium,
                imageAssetName: "ghost_white_sneakers",
                isGhostElement: true
            )
        case .outerwear:
            return WardrobeItem(
                slot: .outerwear,
                formalityScore: 2.5,
                colorProfile: ColorProfile(primaryHex: "#5C5C5C", secondaryHex: nil, category: .neutral),
                pattern: .solid,
                seasonality: [.springFall, .winter],
                fabricWeight: .medium,
                imageAssetName: "ghost_neutral_jacket",
                isGhostElement: true
            )
        }
    }

    /// Returns `inventory` with a ghost element appended for every slot that
    /// has zero items in it.
    static func ensureGhostElements(in inventory: [WardrobeItem]) -> [WardrobeItem] {
        var result = inventory
        for slot in Slot.allCases where !inventory.contains(where: { $0.slot == slot }) {
            result.append(defaultItem(for: slot))
        }
        return result
    }
}
