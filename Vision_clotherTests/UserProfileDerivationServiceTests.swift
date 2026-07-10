//
//  UserProfileDerivationServiceTests.swift
//  Vision_clotherTests
//
//  Covers `MockUserProfileDerivationService` — the keyless-Simulator path for
//  User Style Profile derivation (PRD.md §3.8). Mock only, zero network.
//

import Foundation
import Testing
@testable import Vision_clother

struct UserProfileDerivationServiceTests {

    @Test func mockReturnsItsConfiguredResultRegardlessOfInput() async throws {
        let expected = UserStyleProfileWire(
            skinTone: "deep, cool",
            undertone: .cool,
            bodyType: "petite",
            styleKeywords: ["romantic"],
            recommendedColors: ["#4B0082"],
            avoidColors: ["#FFD700"]
        )
        let service = MockUserProfileDerivationService(result: expected)

        let derived = try await service.deriveProfile(portraitData: Data([0x01, 0x02, 0x03]))

        #expect(derived == expected)
    }

    @Test func defaultMockResultIsAWellFormedProfile() async throws {
        let derived = try await MockUserProfileDerivationService().deriveProfile(portraitData: Data())
        #expect(!derived.skinTone.isEmpty)
        #expect(!derived.styleKeywords.isEmpty)
    }
}
