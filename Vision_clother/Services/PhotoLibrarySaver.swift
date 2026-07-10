//
//  PhotoLibrarySaver.swift
//  Vision_clother
//
//  Writes a saved combination's generated image to the user's Photos
//  library, in addition to the durable app-local copy `ImageStorage` keeps.
//  On-device only (CLAUDE.md guardrail #4) — no API key gate, same posture
//  as `VisionPersonPhotoValidationService`. Requests `.addOnly` authorization
//  so the app never needs read access to the rest of the user's library.
//

import Foundation
import Photos

protocol PhotoLibrarySaver {
    /// Throws a `PhotoLibrarySaveError` if the write fails or permission is
    /// denied; returns normally otherwise. Callers treat failure here as
    /// non-fatal — the app-local save via `ImageStorage` already succeeded.
    func save(imageData: Data) async throws
}

enum PhotoLibrarySaveError: Error, LocalizedError, Equatable {
    case permissionDenied
    case writeFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Vision Clother isn't allowed to save photos. Enable photo access in Settings to also save to your library."
        case .writeFailed(let reason):
            return "Couldn't save that photo: \(reason)"
        }
    }
}

final class PHPhotoLibraryImageSaver: PhotoLibrarySaver {
    func save(imageData: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.permissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imageData, options: nil)
            }
        } catch {
            throw PhotoLibrarySaveError.writeFailed(reason: error.localizedDescription)
        }
    }
}

// MARK: - Mock for previews/tests — never touches PHPhotoLibrary.

struct MockPhotoLibrarySaver: PhotoLibrarySaver {
    var errorToThrow: PhotoLibrarySaveError?

    func save(imageData: Data) async throws {
        if let errorToThrow {
            throw errorToThrow
        }
    }
}
