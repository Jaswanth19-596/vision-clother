//
//  GhostElementProviderTests.swift
//  Vision_clotherTests
//
//  Covers PRD.md §3.2's Virtual Capsule Injection: every slot must have a
//  candidate, real or ghost, and ghost elements never displace real items.
//

import Testing
@testable import Vision_clother

struct GhostElementProviderTests {

    @Test func emptyInventoryGetsExactlyOneGhostPerSlot() {
        let result = GhostElementProvider.ensureGhostElements(in: [])

        #expect(result.count == Slot.allCases.count)
        for slot in Slot.allCases {
            let matches = result.filter { $0.slot == slot }
            #expect(matches.count == 1)
            #expect(matches.first?.isGhostElement == true)
        }
    }

    @Test func realItemInASlotSuppressesItsGhost() {
        let realTop = WardrobeItem(
            slot: .top,
            formalityScore: 3,
            colorProfile: ColorProfile(primaryHex: "#123456", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: [.summer],
            fabricWeight: .light
        )

        let result = GhostElementProvider.ensureGhostElements(in: [realTop])

        let tops = result.filter { $0.slot == .top }
        #expect(tops.count == 1)
        #expect(tops.first?.isGhostElement == false)

        // The other three slots still get a ghost each.
        #expect(result.filter { $0.slot == .bottom }.first?.isGhostElement == true)
        #expect(result.filter { $0.slot == .footwear }.first?.isGhostElement == true)
        #expect(result.filter { $0.slot == .outerwear }.first?.isGhostElement == true)
    }

    @Test func ghostDefaultsAreAllSeason() {
        // Ghost elements must never be filtered out by a season constraint —
        // otherwise a mandatory slot could end up with zero candidates.
        for slot in Slot.allCases {
            let ghost = GhostElementProvider.defaultItem(for: slot)
            for season in Season.allCases where slot != .outerwear {
                #expect(ghost.seasonality.contains(season))
            }
        }
    }
}
