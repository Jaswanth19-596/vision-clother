//
//  OpenRouterResponseParsing.swift
//  Vision_clother
//
//  Shared tolerant-parsing helper for the `response_format`-unsupported
//  fallback path in both OpenRouterIntentExtractionService.swift and
//  VisionMetadataExtractionService.swift — strips a markdown code fence (if
//  present) and takes the outermost `{...}` span, so a model that ignores
//  `response_format` and wraps or annotates its JSON reply still parses.
//

import Foundation

enum OpenRouterResponseParsing {
    static func extractJSONObject(from text: String) -> Data {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let firstBrace = trimmed.firstIndex(of: "{"), let lastBrace = trimmed.lastIndex(of: "}"), firstBrace < lastBrace {
            trimmed = String(trimmed[firstBrace...lastBrace])
        }
        return Data(trimmed.utf8)
    }
}
