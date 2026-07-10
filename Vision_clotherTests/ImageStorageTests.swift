//
//  ImageStorageTests.swift
//  Vision_clotherTests
//
//  On-disk persistence for ingested garment photos (see Data/ImageStorage.swift).
//

import Foundation
import Testing
@testable import Vision_clother

struct ImageStorageTests {

    @Test func savedDataRoundTripsThroughURL() throws {
        let original = Data([0xAB, 0xCD, 0xEF, 0x01])
        let filename = try ImageStorage.save(original)
        defer { ImageStorage.delete(filename) }

        let loaded = try Data(contentsOf: ImageStorage.url(for: filename))
        #expect(loaded == original)
    }

    @Test func eachSaveGetsAUniqueFilename() throws {
        let first = try ImageStorage.save(Data([0x01]))
        let second = try ImageStorage.save(Data([0x02]))
        defer {
            ImageStorage.delete(first)
            ImageStorage.delete(second)
        }

        #expect(first != second)
    }

    @Test func deleteRemovesTheFile() throws {
        let filename = try ImageStorage.save(Data([0x01]))
        ImageStorage.delete(filename)

        #expect(!FileManager.default.fileExists(atPath: ImageStorage.url(for: filename).path))
    }

    @Test func deletingAMissingFileDoesNotThrow() {
        // Best-effort cleanup — a file that's already gone (or never
        // existed) must not surface as an error to the caller.
        ImageStorage.delete("never-existed.png")
    }
}
