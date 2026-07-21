//
//  RemoteConfigManager.swift
//  Vision_clother
//
//  Firebase Remote Config wrapper for the AI model/payload knobs consumed by
//  `Config/ModelConfig.swift` — lets an OpenRouter model deprecation or
//  misbehavior be hotfixed from the Firebase Console with zero app build/App
//  Store release. Every key is registered with a baked-in default
//  (`Defaults` below) via `setDefaults` at init, and Firebase's own SDK falls
//  back to that default for any key that hasn't been fetched/activated yet
//  — so every reader below works identically offline, before the first
//  fetch, or if `fetchAndActivate()` fails, with no manual "did we fetch?"
//  branching needed at call sites.
//

import FirebaseRemoteConfig
import Foundation

final class RemoteConfigManager {
    static let shared = RemoteConfigManager()

    enum Key: String, CaseIterable {
        case primaryModelName = "ai_primary_model_name"
        case fallbackModelName = "ai_fallback_model_name"
        case temperature = "ai_temperature"
        case enableStrictJSONSchema = "ai_enable_strict_json_schema"
        case maxTokens = "ai_max_tokens"
        case imageToTextModelName = "ai_image_to_text_model_name"
        case imageToImageModelName = "ai_image_to_image_model_name"
        case imageEditModelName = "ai_image_edit_model_name"
    }

    /// Local fallback values — identical to what `ModelConfig` hardcoded
    /// before this wrapper existed. Import these into the Firebase Console
    /// per `docs/backend/conventions.md`'s Remote Config table; never delete
    /// a key here without removing it from that table too.
    enum Defaults {
        static let primaryModelName = "google/gemini-3.1-flash-lite"
        static let fallbackModelName = "openai/gpt-5-mini"
        static let temperature = 0.0
        static let enableStrictJSONSchema = true
        static let maxTokens = 4096
        static let imageToTextModelName = "minimax/minimax-m3"
        static let imageToImageModelName = "google/gemini-3.1-flash-lite-image"
        static let imageEditModelName = "google/gemini-3.1-flash-lite-image"
    }

    private let remoteConfig: RemoteConfig

    private init() {
        remoteConfig = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = 3600
        remoteConfig.configSettings = settings
        remoteConfig.setDefaults([
            Key.primaryModelName.rawValue: Defaults.primaryModelName as NSObject,
            Key.fallbackModelName.rawValue: Defaults.fallbackModelName as NSObject,
            Key.temperature.rawValue: Defaults.temperature as NSObject,
            Key.enableStrictJSONSchema.rawValue: Defaults.enableStrictJSONSchema as NSObject,
            Key.maxTokens.rawValue: Defaults.maxTokens as NSObject,
            Key.imageToTextModelName.rawValue: Defaults.imageToTextModelName as NSObject,
            Key.imageToImageModelName.rawValue: Defaults.imageToImageModelName as NSObject,
            Key.imageEditModelName.rawValue: Defaults.imageEditModelName as NSObject,
        ])
    }

    /// Best-effort — call once at app startup (`FirebaseBootstrap.configure()`).
    /// Never throws to the caller: a failed or offline fetch just leaves
    /// every reader below returning the last-activated (or baked-in default)
    /// value, which is the intended graceful-degradation behavior.
    func fetchAndActivate() async {
        do {
            let status = try await remoteConfig.fetchAndActivate()
            AppLog.info(.remoteConfig, "fetchAndActivate: status=\(status.rawValue) primaryModel=\(primaryModelName)")
        } catch {
            AppLog.error(.remoteConfig, "fetchAndActivate: failed, using cached/default values — \(String(describing: error))")
        }
    }

    var primaryModelName: String { remoteConfig[Key.primaryModelName.rawValue].stringValue }
    var fallbackModelName: String { remoteConfig[Key.fallbackModelName.rawValue].stringValue }
    var temperature: Double { remoteConfig[Key.temperature.rawValue].numberValue.doubleValue }
    var enableStrictJSONSchema: Bool { remoteConfig[Key.enableStrictJSONSchema.rawValue].boolValue }
    var maxTokens: Int { remoteConfig[Key.maxTokens.rawValue].numberValue.intValue }
    var imageToTextModelName: String { remoteConfig[Key.imageToTextModelName.rawValue].stringValue }
    var imageToImageModelName: String { remoteConfig[Key.imageToImageModelName.rawValue].stringValue }
    var imageEditModelName: String { remoteConfig[Key.imageEditModelName.rawValue].stringValue }
}
