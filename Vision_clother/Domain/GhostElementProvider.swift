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
    /// lightweight jacket is used to keep the four ghost-backed slots
    /// symmetric. Returns `nil` for slots where `Slot.hasGhostDefault` is
    /// `false` (headwear/accessory/bag) — these are optional accents, not
    /// required for outfit completeness, so there's no completeness gap to
    /// backfill and no universally-neutral placeholder the way "white tee"
    /// is for a core slot. Stays an exhaustive switch (rather than trusting
    /// callers never to invoke it for a non-ghost slot) so a future slot
    /// added without updating this function fails to compile, not silently.
    static func defaultItem(for slot: Slot) -> WardrobeItem? {
        switch slot {
        case .headwear, .accessory, .bag:
            return nil
        case .top:
            return WardrobeItem(
                id: stableID(for: .top),
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
                id: stableID(for: .bottom),
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
                id: stableID(for: .footwear),
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
                id: stableID(for: .outerwear),
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

    /// Ghost elements are synthesized fresh on every `displayItems` access
    /// (they're never persisted), so they need a fixed id per slot rather
    /// than the model's default random `UUID()` — otherwise the id captured
    /// by a tap gesture and the id in the array handed to the detail sheet
    /// come from two different evaluations and never match, leaving the
    /// detail view blank. These UUIDs are arbitrary but must stay constant.
    private static func stableID(for slot: Slot) -> UUID {
        switch slot {
        case .top: return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .bottom: return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case .footwear: return UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        case .outerwear: return UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        case .headwear, .accessory, .bag:
            preconditionFailure("\(slot) has no ghost default — stableID should never be called for it")
        }
    }

    /// Returns `inventory` with a ghost element appended for every
    /// ghost-backed slot (`Slot.hasGhostDefault`) that has zero items in it.
    /// Optional-accent slots (headwear/accessory/bag) are deliberately left
    /// empty rather than ghost-filled — see `defaultItem(for:)`.
    static func ensureGhostElements(in inventory: [WardrobeItem]) -> [WardrobeItem] {
        var result = inventory
        for slot in Slot.allCases where slot.hasGhostDefault && !inventory.contains(where: { $0.slot == slot }) {
            if let ghost = defaultItem(for: slot) {
                result.append(ghost)
            }
        }
        return result
    }
}
