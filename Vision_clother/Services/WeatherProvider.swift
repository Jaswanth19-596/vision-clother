//
//  WeatherProvider.swift
//  Vision_clother
//
//  Wires up current weather (PRD.md §2.1/§2.1a) — `WeatherContext` and the
//  intent/recommendation LLM calls already supported it, but the Daily
//  Assistant call site passed `nil` until the 2026-07-10 LLM-as-Recommender
//  reversal (docs/decisions/resolved-v1.md). `WeatherKitWeatherProvider` is
//  a placeholder for a real WeatherKit-backed implementation — it requires
//  the WeatherKit entitlement/capability, which is a follow-up outside this
//  change's scope, so `ServiceFactory` defaults to the mock so the app stays
//  fully interactive without it.
//

import Foundation

protocol CurrentWeatherProviding {
    /// Returns the best-available current weather, or `nil` if unavailable
    /// (permission denied, no location, provider error) — callers must treat
    /// `nil` as "no weather signal," not an error.
    func currentWeather() async -> WeatherContext?
}

struct MockCurrentWeatherProvider: CurrentWeatherProviding {
    var result: WeatherContext? = WeatherContext(temperatureFahrenheit: 68, conditions: "Partly Cloudy")

    func currentWeather() async -> WeatherContext? {
        result
    }
}

/// Placeholder for a real WeatherKit-backed implementation — requires the
/// WeatherKit capability/entitlement to be added to the app target first
/// (follow-up, out of scope here). Until then this behaves identically to
/// returning no weather signal, so callers degrade gracefully rather than
/// crashing on a missing entitlement.
final class WeatherKitWeatherProvider: CurrentWeatherProviding {
    func currentWeather() async -> WeatherContext? {
        nil
    }
}
