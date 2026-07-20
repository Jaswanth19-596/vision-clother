//
//  AnalyticsLog.swift
//  Vision_clother
//
//  Shared diagnostic logger for the Analytics & Insights aggregation
//  pipeline — every line tagged `[Insights]`, same posture as
//  `Domain/MLLog.swift`'s `[AI-Stylist-ML]` tag. Lives in Domain/ (rather
//  than reusing `Diagnostics/AppLog.swift`) so `Domain/AnalyticsAggregator.swift`
//  stays free of anything below the Domain layer, per Domain/CLAUDE.md and
//  `Diagnostics/AppLog.swift`'s own doc comment ("every subsystem below the
//  Domain-layer's MLLog... routes through here").
//

import Foundation
import os

enum AnalyticsLog {
    static let logger = Logger(subsystem: "com.visionclother", category: "Insights")
}
