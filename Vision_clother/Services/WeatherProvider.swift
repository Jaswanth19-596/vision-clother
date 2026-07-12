//
//  WeatherProvider.swift
//  Vision_clother
//
//  Wires up current weather (PRD.md §2.1/§2.1a) — `WeatherContext` and the
//  intent/recommendation LLM calls already supported it, but the Daily
//  Assistant call site passed `nil` until the 2026-07-10 LLM-as-Recommender
//  reversal (docs/decisions/resolved-v1.md). `OpenMeteoWeatherProvider` is
//  the real implementation: CoreLocation for the device's coordinates, then
//  Open-Meteo's free, keyless REST API for the current reading — no
//  WeatherKit entitlement/Apple Developer Program capability needed, so it
//  works out of the box in Simulator and on device alike.
//

import CoreLocation
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

/// One-shot async wrapper around `CLLocationManager` — the delegate callbacks
/// are bridged to a single `CheckedContinuation`, resumed exactly once by
/// whichever callback fires first (success, failure, or an authorization
/// change that isn't actually authorized).
private final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                finish(with: nil)
            @unknown default:
                finish(with: nil)
            }
        }
    }

    private func finish(with location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(with: nil)
        case .notDetermined:
            break
        @unknown default:
            finish(with: nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }
}

/// Real implementation — CoreLocation for coordinates, Open-Meteo
/// (https://open-meteo.com, free and keyless) for the current reading.
/// Degrades to `nil` on any failure (no location permission, no signal,
/// network error, decoding error) per the protocol's contract, rather than
/// throwing — a missing weather signal is expected/routine, not exceptional.
final class OpenMeteoWeatherProvider: CurrentWeatherProviding {
    private let session: URLSession
    private let locationFetcher: OneShotLocationFetcher

    init(session: URLSession = .shared) {
        self.session = session
        self.locationFetcher = OneShotLocationFetcher()
    }

    func currentWeather() async -> WeatherContext? {
        guard let location = await locationFetcher.currentLocation() else {
            return nil
        }
        return await fetchWeather(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    private func fetchWeather(latitude: Double, longitude: Double) async -> WeatherContext? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            return WeatherContext(
                temperatureFahrenheit: decoded.current.temperature2m,
                conditions: Self.conditions(forWMOCode: decoded.current.weatherCode)
            )
        } catch {
            return nil
        }
    }

    /// Maps Open-Meteo's WMO weather codes to a short human-readable label.
    /// https://open-meteo.com/en/docs — "WMO Weather interpretation codes"
    private static func conditions(forWMOCode code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67: return "Rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Rain Showers"
        case 85, 86: return "Snow Showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Unknown"
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }
    let current: Current
}
