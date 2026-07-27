//
//  ItemNote.swift
//  Vision_clother
//
//  Item-Level Feedback (2026-07-27): a short, condensed, *current-state*
//  claim about one garment — "runs loose", "not warm enough" — as distinct
//  from the taste signal `Models/ItemRating.swift` carries.
//
//  Deliberately **mutable**, and deliberately the only feedback table in this
//  app that isn't event-sourced. `ItemRating`, `OutfitFeedback` and
//  `SwipeAttributeEvent` are all append-only because they feed a time-decayed
//  aggregate where the history *is* the signal. A note is not history: it's a
//  property of the garment that stays true until the user says otherwise, and
//  they must be able to edit or delete it (`Features/Closet`'s "Your notes"
//  section). Modeling it append-only would require tombstones and
//  override-event layering to express "that note was wrong" — complexity that
//  buys nothing, since no decayed aggregate reads it.
//
//  Critically, a note never touches `Domain/AttributePreferenceProfile.swift`.
//  "This shirt is loose" is a fact about one garment, not a preference: the
//  user may well love relaxed fits in general, and folding it into
//  `fitAffinity` would teach "dislikes loose" and suppress every relaxed
//  garment they own. Taste chips write `ItemRating`; defect chips write this.
//  See `docs/decisions/stylist-intelligence-engine.md`.
//

import Foundation
import SwiftData

/// How strongly a note suppresses its item, and therefore which enforcement
/// path it takes. The two are genuinely different mechanisms, not two points
/// on one scale — see `Domain/StylistBrain.swift`'s `itemSuitability` tier.
enum ItemNoteSeverity: String, Codable, CaseIterable, Identifiable {
    /// The common case ("runs loose", "not warm enough"): the item is still
    /// perfectly wearable, just wrong for *some* occasions. Reaches the
    /// recommendation LLM as a per-item `user_note` under the `itemSuitability`
    /// tier, with a deterministic penalty in
    /// `Domain/OutfitRecommendationEngine.outfitScore` when the note's
    /// `context` conflicts with the request's resolved constraints.
    case conditional
    /// The item is effectively out of rotation (doesn't fit anymore, damaged,
    /// given away). Enforced by **excluding it from the catalog entirely** in
    /// `Domain/WardrobeCatalogBuilder.swift` rather than as a prompt rule —
    /// the LLM can't pick what it never sees, so this is unbypassable and
    /// costs zero tokens, where a prompt rule is only as good as model
    /// compliance. Same premise Tier 1's "only use items in the catalog"
    /// already rests on.
    case blocking

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conditional: return "Depends on the occasion"
        case .blocking: return "Don't suggest this anymore"
        }
    }
}

/// Where a note came from. Surfaced in the Closet UI so an LLM-extracted note
/// that landed on the wrong garment is visibly *inferred* and obviously
/// editable — misattribution is the main failure mode of the free-text path
/// (`Services/CombinationChemistryInferenceService.swift`), and this is its
/// safety valve.
enum ItemNoteSource: String, Codable, CaseIterable {
    /// One tap on a per-slot chip (`Domain/ItemFeedbackChip.swift`) — a
    /// deterministic lookup, no LLM involved.
    case chip
    /// Extracted from the user's free-text combination comment by the
    /// chemistry-inference call.
    case inferred
    /// Typed or edited by the user directly in Closet.
    case user

    var label: String {
        switch self {
        case .chip: return "From feedback"
        case .inferred: return "From your comment"
        case .user: return "Yours"
        }
    }
}

/// The situation in which a `conditional` note actually bites. Lets
/// `outfitScore` apply the penalty only where it's earned — "runs loose"
/// costs nothing for weekend brunch and a lot for an interview — instead of
/// a flat penalty that would make any noted item globally less likely.
///
/// Every case must be answerable *deterministically* from data
/// `outfitScore` already receives (`StyleConstraints`, `WeatherContext`);
/// anything requiring judgment belongs in the prompt, not here.
enum ItemNoteContext: String, Codable, CaseIterable {
    /// Fit/appearance defects that matter most when dressed up.
    case formalOccasions
    /// "Not warm enough."
    case coldWeather
    /// "Too warm."
    case hotWeather
    /// Comfort defects that matter whenever the garment is worn for a while
    /// — no external condition gates these, so they carry a smaller,
    /// always-applied penalty.
    case extendedWear
    /// Mild/aesthetic notes with no deterministic trigger — prompt-only, no
    /// scoring penalty at all.
    case none
}

/// One condensed note about a garment. Keyed by `WardrobeItem.id` (the app's
/// single stable item identifier, per `CLAUDE.md`), never by a second id.
@Model
final class ItemNote {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    /// Short, human-readable, and shown verbatim both in Closet and (for
    /// `conditional` notes) in the recommendation catalog — so it must read
    /// as a clause, not a sentence: "runs loose", not "The user says this
    /// shirt runs loose." Length-capped at write time by
    /// `Data/WardrobeRepository.swift`.
    var text: String
    /// Raw-string-backed enums, matching `OutfitFeedback.swipeSentimentRaw`'s
    /// posture — keeps lightweight schema migrations trivial and avoids
    /// SwiftData's macro limitations around enum defaults.
    var severityRaw: String = ItemNoteSeverity.conditional.rawValue
    var sourceRaw: String = ItemNoteSource.chip.rawValue
    var contextRaw: String = ItemNoteContext.none.rawValue
    var createdAt: Date
    /// Bumped on every edit — this is a mutable row, so `updatedAt` (not
    /// `createdAt`) is what sync conflict resolution compares.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        itemID: UUID,
        text: String,
        severity: ItemNoteSeverity = .conditional,
        source: ItemNoteSource = .chip,
        context: ItemNoteContext = .none,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.itemID = itemID
        self.text = text
        self.severityRaw = severity.rawValue
        self.sourceRaw = source.rawValue
        self.contextRaw = context.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var severity: ItemNoteSeverity {
        ItemNoteSeverity(rawValue: severityRaw) ?? .conditional
    }

    var source: ItemNoteSource {
        ItemNoteSource(rawValue: sourceRaw) ?? .chip
    }

    var context: ItemNoteContext {
        ItemNoteContext(rawValue: contextRaw) ?? .none
    }

    /// Max stored length. Notes are joined into `CatalogEntry.userNote` and
    /// sent to the recommendation LLM for every item that has one, so an
    /// unbounded note would let one garment consume a meaningful slice of the
    /// prompt budget.
    static let maxTextLength = 60

    /// Trims and truncates arbitrary text (a user edit, or an LLM-extracted
    /// clause) to something safe to store and prompt with.
    static func normalizedText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTextLength else { return trimmed }
        return String(trimmed.prefix(maxTextLength))
    }
}
