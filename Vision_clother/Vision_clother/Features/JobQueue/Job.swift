//
//  Job.swift
//  Vision_clother
//
//  A single background job tracked by `JobQueueStore` — either a wardrobe
//  item upload (background isolation -> vision-LLM tagging -> save) or a
//  try-on render.
//

import Foundation

struct Job: Identifiable {
    enum Kind {
        case upload(UploadPayload)
        case tryOn(TryOnPayload)
    }

    enum Status: Equatable {
        case queued
        case processing(String)
        case succeeded
        case failed(String)

        var isInFlight: Bool {
            switch self {
            case .queued, .processing: return true
            case .succeeded, .failed: return false
            }
        }
    }

    let id: UUID
    let kind: Kind
    var status: Status
    let createdAt: Date
    var completedAt: Date?
    /// Raw (pre-isolation) photo for uploads, the user's portrait for
    /// try-ons — rendered as the queue row's thumbnail.
    var thumbnail: Data?
    /// Set on upload success.
    var resultItemID: UUID?
    /// Set on try-on terminal state, so the panel can reopen
    /// `TryOnResultView` with the exact result it ended on.
    var tryOnResultState: TryOnState?

    init(id: UUID = UUID(), kind: Kind, thumbnail: Data?, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.status = .queued
        self.createdAt = createdAt
        self.completedAt = nil
        self.thumbnail = thumbnail
        self.resultItemID = nil
        self.tryOnResultState = nil
    }
}

struct UploadPayload {
    let rawImageData: Data
    let defaultSlot: Slot?
}

struct TryOnPayload {
    let baseImageData: Data
    let outfit: OutfitCombination
}
