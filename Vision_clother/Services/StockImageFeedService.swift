//
//  StockImageFeedService.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste: sources the swipe deck from a licensed
//  stock-photo API — Pexels, chosen over Unsplash for its simpler
//  attribution-only licensing (Unsplash also requires a "download trigger"
//  API ping on every use). Raw URLSession, typed Codable response, same
//  protocol-first pattern as every other Services/ file (Services/CLAUDE.md)
//  — mock swap gated on `APIKeys.pexels` via `ServiceFactory`, same posture
//  as the OpenRouter-backed services.
//

import Foundation

/// One stock photo offered in the swipe deck — deliberately thin (no raw
/// image bytes): the view downloads/displays `imageURLString` itself
/// (`AsyncImage`), and the downloaded bytes are only ever embedded
/// (`Services/ImageEmbeddingService.swift`) once the user actually swipes.
struct StockPhoto: Identifiable, Equatable {
    var id: String
    var imageURLString: String
    var photographerName: String
    var photographerURLString: String?

    /// Pexels' license requires visible attribution wherever a photo is
    /// displayed — rendered on-card by `Features/SwipeDiscovery/SwipeDiscoveryView.swift`.
    var attributionText: String {
        "Photo by \(photographerName) on Pexels"
    }
}

protocol StockImageFeedService {
    /// Fetches up to `count` fresh stock photos for one swipe-deck session.
    func fetchDeck(count: Int) async throws -> [StockPhoto]
}

enum StockImageFeedError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case requestFailed(reason: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Pexels API key configured."
        case .requestFailed(let reason):
            return "Couldn't load new photos: \(reason)"
        case .invalidResponse:
            return "Couldn't read the photo feed response."
        }
    }
}

final class PexelsImageFeedService: StockImageFeedService {
    private let session: URLSession
    /// A single generic query like "fashion" pulls back lifestyle/model
    /// photography that isn't actually clothing — narrower, garment-specific
    /// queries keep the deck on-topic for a *clothing* taste signal. One is
    /// picked at random per `fetchDeck` call for session-to-session variety.
    /// Not user-configurable in v1 (see the swipe-deck plan's deferred list).
    private let queryPool: [String]

    init(session: URLSession = .shared, queryPool: [String] = PexelsImageFeedService.defaultQueryPool) {
        self.session = session
        self.queryPool = queryPool
    }

    static let defaultQueryPool: [String] = [
        "menswear street style",
        "mens clothing flatlay",
        "men minimalist style outfit",
        "streetwear men fashion",
        "men smart casual look",
        "mens capsule wardrobe aesthetic",
        "menswear casual details",
        "men summer outfit style" // or swap seasonally (e.g., "men fall layer outfit")
    ]

    func fetchDeck(count: Int) async throws -> [StockPhoto] {
        guard let apiKey = APIKeys.pexels else {
            throw StockImageFeedError.missingAPIKey
        }

        let query = queryPool.randomElement() ?? "clothing outfit"
        var components = URLComponents(string: "https://api.pexels.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: String(min(max(count, 1), 80))),
            // A random page keeps the deck from showing the exact same top
            // results every session — Pexels' search results are stable per
            // query, not freshly shuffled server-side.
            URLQueryItem(name: "page", value: String(Int.random(in: 1...10))),
        ]
        guard let url = components.url else {
            throw StockImageFeedError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        // Pexels expects the raw key in this header — no "Bearer" prefix.
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StockImageFeedError.requestFailed(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw StockImageFeedError.requestFailed(reason: "HTTP \(statusCode)")
        }

        guard let decoded = try? JSONDecoder().decode(PexelsSearchResponse.self, from: data) else {
            throw StockImageFeedError.invalidResponse
        }

        return decoded.photos.map { photo in
            StockPhoto(
                id: String(photo.id),
                imageURLString: photo.src.large,
                photographerName: photo.photographer,
                photographerURLString: photo.photographerURL
            )
        }
    }
}

// MARK: - Pexels wire shapes

private struct PexelsSearchResponse: Decodable {
    let photos: [Photo]

    struct Photo: Decodable {
        let id: Int
        let photographer: String
        let photographerURL: String?
        let src: Source

        enum CodingKeys: String, CodingKey {
            case id, photographer, src
            case photographerURL = "photographer_url"
        }
    }

    struct Source: Decodable {
        let large: String
    }
}

// MARK: - Mock for previews/tests — never touches the network.

struct MockStockImageFeedService: StockImageFeedService {
    var photosToReturn: [StockPhoto]?
    var errorToThrow: StockImageFeedError?

    func fetchDeck(count: Int) async throws -> [StockPhoto] {
        if let errorToThrow {
            throw errorToThrow
        }
        if let photosToReturn {
            return photosToReturn
        }
        return (0..<count).map { i in
            StockPhoto(
                id: "mock-\(i)",
                imageURLString: "https://picsum.photos/seed/\(i)/600/800",
                photographerName: "Mock Photographer",
                photographerURLString: nil
            )
        }
    }
}
