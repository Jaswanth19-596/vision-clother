//
//  ColorHarmonyTests.swift
//  Vision_clotherTests
//
//  Covers Domain/ColorHarmony.swift's hue-relationship math and NaN-safety
//  (Domain/CLAUDE.md) — the real color-theory engine that replaced the old
//  flat "both vibrant" penalty in PairCompatibilityScoring.aestheticPrior.
//

import Testing
@testable import Vision_clother

struct ColorHarmonyTests {

    // MARK: - hsl(fromHex:)

    @Test func malformedHexReturnsNil() {
        #expect(ColorHarmony.hsl(fromHex: "not-a-color") == nil)
        #expect(ColorHarmony.hsl(fromHex: "#12345") == nil)
        #expect(ColorHarmony.hsl(fromHex: "") == nil)
    }

    @Test func hexWithOrWithoutHashParsesIdentically() {
        let withHash = ColorHarmony.hsl(fromHex: "#FF0000")
        let withoutHash = ColorHarmony.hsl(fromHex: "FF0000")
        #expect(withHash?.h == withoutHash?.h)
        #expect(withHash?.s == withoutHash?.s)
        #expect(withHash?.l == withoutHash?.l)
    }

    @Test func pureWhiteAndBlackAreAchromatic() {
        let white = ColorHarmony.hsl(fromHex: "#FFFFFF")
        let black = ColorHarmony.hsl(fromHex: "#000000")
        #expect(white?.s == 0)
        #expect(black?.s == 0)
    }

    // MARK: - harmonyScore

    @Test func malformedHexDegradesToNeutralNeverAPenaltyOrBonus() {
        let score = ColorHarmony.harmonyScore("garbage", "#FF0000")
        #expect(score == 0.5)
    }

    @Test func achromaticColorPairsSafelyWithAnything() {
        // White (achromatic) next to a saturated red — should score high
        // regardless of the red's hue.
        let score = ColorHarmony.harmonyScore("#FFFFFF", "#FF0000")
        #expect(score >= 0.8)
    }

    @Test func identicalHueScoresAsMonochromeHigh() {
        let score = ColorHarmony.harmonyScore("#3A7CA5", "#3A7CA5")
        #expect(score >= 0.85)
    }

    @Test func complementaryHuesScoreHigherThanAMidHueClash() {
        // Red (~0°) vs. cyan-ish (~180°, complementary) should beat
        // red vs. a saturated yellow-green (~90°, the clash zone).
        let complementary = ColorHarmony.harmonyScore("#E53935", "#00ACC1")
        let clash = ColorHarmony.harmonyScore("#E53935", "#8BC34A")
        #expect(complementary > clash)
    }

    @Test func harmonyScoreIsAlwaysWithinZeroToOne() {
        let hexes = ["#FFFFFF", "#000000", "#FF0000", "#00FF00", "#0000FF", "#123456", "not-a-color", ""]
        for a in hexes {
            for b in hexes {
                let score = ColorHarmony.harmonyScore(a, b)
                #expect(score >= 0 && score <= 1)
                #expect(!score.isNaN)
            }
        }
    }

    // MARK: - undertoneCompatibility

    @Test func undertoneCompatibilityMatrix() {
        #expect(ColorHarmony.undertoneCompatibility(.warm, .warm) == 1.0)
        #expect(ColorHarmony.undertoneCompatibility(.cool, .cool) == 1.0)
        #expect(ColorHarmony.undertoneCompatibility(.neutral, .warm) == 0.75)
        #expect(ColorHarmony.undertoneCompatibility(.cool, .neutral) == 0.75)
        #expect(ColorHarmony.undertoneCompatibility(.warm, .cool) == 0.4)
        #expect(ColorHarmony.undertoneCompatibility(nil, .warm) == 0.5)
        #expect(ColorHarmony.undertoneCompatibility(nil, nil) == 0.5)
    }
}
