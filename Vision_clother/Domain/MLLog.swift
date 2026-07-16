//
//  MLLog.swift
//  Vision_clother
//
//  Shared diagnostic logger for the Swipe-to-Learn Visual Taste pipeline —
//  every line is tagged `[AI-Stylist-ML]` so it's easy to isolate in the
//  Console. Kept in Domain/ (rather than reusing `Services/PerfLog.swift`)
//  so `Domain/WardrobeCatalogBuilder.swift` doesn't need a Services/
//  dependency (Domain/CLAUDE.md forbids that); `Data/WardrobeRepository.swift`
//  already depends on Domain/ for the centroid/scoring math this logs, so
//  reusing this logger there too keeps every [AI-Stylist-ML] line coming
//  from one definition.
//

import Foundation
import os

enum MLLog {
    static let logger = Logger(subsystem: "com.visionclother", category: "AI-Stylist-ML")
}
