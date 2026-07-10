//
//  APIKeys.swift
//  Vision_clother
//
//  DEV ONLY — reads provider keys from a bundled `Secrets.plist` (gitignored;
//  see `Config/Secrets.example.plist` for the expected keys and
//  `Config/README.md` for setup instructions). Calling OpenRouter/Fal
//  directly from the app with an embedded key is acceptable for personal
//  development and testing only. Never ship a distributed build
//  (TestFlight/App Store) this way — before real distribution, move these
//  calls behind a thin proxy backend that holds the keys server-side. See
//  CLAUDE.md §5.
//

import Foundation

enum APIKeys {
    static var openRouter: String? {
        value(for: "OPENROUTER_API_KEY")
    }

    static var fal: String? {
        value(for: "FAL_API_KEY")
    }

    /// `nil` both when the key is genuinely blank and when `Secrets.plist`
    /// hasn't been created yet — callers should treat both cases identically
    /// and fall back to the mock service rather than crash.
    private static func value(for key: String) -> String? {
        var plistData: Data? = nil
        
        // 1. Try to read from Main Bundle
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist") {
            plistData = try? Data(contentsOf: url)
        }
        
        // 2. Local development fallback for iOS Simulator (avoid bundling quirks)
        #if DEBUG
        if plistData == nil {
            let localPath = "/Users/jaswanth/mydocs/ios-apps/vision_clother/Vision_clother/Vision_clother/Config/Secrets.plist"
            let localURL = URL(fileURLWithPath: localPath)
            if let data = try? Data(contentsOf: localURL) {
                print("🔑 Local Fallback: Successfully loaded Secrets.plist directly from absolute path: \(localPath)")
                plistData = data
            }
        }
        #endif
        
        guard let data = plistData else {
            print("⚠️ Secrets.plist NOT FOUND in main bundle or local workspace path.")
            return nil
        }
        
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            print("⚠️ Could not parse Secrets.plist as [String: String]")
            return nil
        }
        guard let raw = plist[key] else {
            print("⚠️ Key '\(key)' NOT found in Secrets.plist")
            return nil
        }
        if raw.isEmpty {
            print("⚠️ Key '\(key)' is empty in Secrets.plist")
            return nil
        }
        print("🔑 Successfully loaded key '\(key)' from Secrets.plist")
        return raw
    }
}
