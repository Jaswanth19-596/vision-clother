//
//  TasteSynthesisTests.swift
//  Vision_clotherTests
//
//  Covers Domain/TasteSynthesis.swift: thresholding, ranking by magnitude,
//  and the empty/sparse-profile case — pure construction, zero mocking,
//  same style as AttributePreferenceProfileTests.swift.
//

import Foundation
import Testing
@testable import Vision_clother

struct TasteSynthesisTests {

    @Test func emptyProfileYieldsNoSignals() {
        let profile = AttributePreferenceProfile()

        let signals = TasteSynthesis.rank(from: profile)

        #expect(signals.isEmpty)
    }

    @Test func belowThresholdAffinitiesAreExcluded() {
        var profile = AttributePreferenceProfile()
        // Just shy of the confidence threshold on every axis.
        profile.colorVibeAffinity = [.vibrant: 0.55]
        profile.patternAffinity = [.graphic: 0.55]
        profile.formalityAffinity = [2: 0.55]
        profile.silhouetteAffinity = ["oversized": 0.55]
        profile.fabricWeightAffinity = [.light: 0.55]

        let signals = TasteSynthesis.rank(from: profile)

        #expect(signals.isEmpty)
    }

    @Test func aboveThresholdColorInSlotIsSurfaced() {
        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinityBySlot = [.top: [.earthTones: 0.8]]

        let signals = TasteSynthesis.rank(from: profile)

        #expect(signals == [.colorInSlot(slot: .top, vibe: .earthTones, affinity: 0.8)])
    }

    @Test func avoidedColorIsSurfacedAtOrBelowAvoidThreshold() {
        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinity = [.monochrome: 0.2]

        let signals = TasteSynthesis.rank(from: profile)

        #expect(signals == [.avoidedColor(.monochrome, affinity: 0.2)])
    }

    @Test func rankingSortsByDistanceFromNeutralDescending() {
        var profile = AttributePreferenceProfile()
        profile.formalityAffinity = [3: 0.65]       // magnitude 0.15
        profile.patternAffinity = [.solid: 0.95]    // magnitude 0.45

        let signals = TasteSynthesis.rank(from: profile)

        #expect(signals == [.pattern(.solid, affinity: 0.95), .formalitySweetSpot(band: 3, affinity: 0.65)])
    }

    @Test func limitCapsTheNumberOfSignalsReturned() {
        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinity = [.vibrant: 0.9]
        profile.patternAffinity = [.solid: 0.9]
        profile.formalityAffinity = [3: 0.9]
        profile.silhouetteAffinity = ["oversized": 0.9]
        profile.fabricWeightAffinity = [.light: 0.9]

        let signals = TasteSynthesis.rank(from: profile, limit: 2)

        #expect(signals.count == 2)
    }
}
