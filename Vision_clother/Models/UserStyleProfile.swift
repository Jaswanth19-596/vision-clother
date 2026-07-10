//
//  UserStyleProfile.swift
//  Vision_clother
//
//  User Style Profile (PRD.md §3.8), derived once from the existing
//  onboarding portrait photo (`Services/UserPortraitStorage.swift`) via
//  `Services/UserProfileDerivationService.swift` and fed into the
//  recommendation LLM call (PRD §3.7) to personalize picks. This is the only
//  recommendation-adjacent call that sends an image, and it happens once per
//  derivation, never per recommendation request.
//
//  Two types live here per Models/CLAUDE.md's wire-vs-persisted split:
//  `UserStyleProfileWire` is the untrusted vision-LLM response (explicit
//  snake_case `CodingKeys`); `UserStyleProfile` is the single-row SwiftData
//  model built from it. Mapping happens at the call site
//  (`Data/WardrobeRepository.swift`'s `saveUserProfile`), not here.
//

import Foundation
import SwiftData

struct UserStyleProfileWire: Codable, Equatable {
    var skinTone: String
    var undertone: Undertone
    var bodyType: String
    var styleKeywords: [String]
    var recommendedColors: [String]
    var avoidColors: [String]

    enum CodingKeys: String, CodingKey {
        case skinTone = "skin_tone"
        case undertone
        case bodyType = "body_type"
        case styleKeywords = "style_keywords"
        case recommendedColors = "recommended_colors"
        case avoidColors = "avoid_colors"
    }
}

/// Single-row persisted profile — there is exactly one per user, mirroring
/// `Services/UserPortraitStorage.swift`'s "one portrait" posture, but kept in
/// SwiftData (not disk) since it's structured, queryable data that
/// `Features/Analytics/AnalyticsView.swift` renders, with no image blob to
/// store. `Data/WardrobeRepository.swift.saveUserProfile` upserts this
/// single row rather than accumulating history.
@Model
final class UserStyleProfile {
    @Attribute(.unique) var id: UUID
    var skinTone: String
    /// Stored as the enum's rawValue — SwiftData `@Model` properties must be
    /// primitive-Codable-compatible; `Undertone` itself is `String`-backed
    /// so this round-trips exactly via `Undertone(rawValue:)`.
    var undertoneRaw: String
    var bodyType: String
    var styleKeywords: [String]
    var recommendedColors: [String]
    var avoidColors: [String]
    var derivedAt: Date

    init(
        id: UUID = UUID(),
        skinTone: String,
        undertone: Undertone,
        bodyType: String,
        styleKeywords: [String],
        recommendedColors: [String],
        avoidColors: [String],
        derivedAt: Date = .now
    ) {
        self.id = id
        self.skinTone = skinTone
        self.undertoneRaw = undertone.rawValue
        self.bodyType = bodyType
        self.styleKeywords = styleKeywords
        self.recommendedColors = recommendedColors
        self.avoidColors = avoidColors
        self.derivedAt = derivedAt
    }

    var undertone: Undertone {
        Undertone(rawValue: undertoneRaw) ?? .neutral
    }
}
