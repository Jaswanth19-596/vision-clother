//
//  UserPortraitStorageTests.swift
//  Vision_clotherTests
//
//  On-disk persistence for the user's own try-on photo (see
//  Services/UserPortraitStorage.swift).
//
//  Serialized because every test here shares the one fixed file
//  UserPortraitStorage writes to (by design — see its header) — running
//  them concurrently would race on that file. ManualPairingViewModelTests
//  touches the same storage and is serialized for the same reason.
//

import Foundation
import Testing
@testable import Vision_clother

@Suite(.serialized)
struct UserPortraitStorageTests {

    @Test func savedDataRoundTrips() throws {
        UserPortraitStorage.delete()
        defer { UserPortraitStorage.delete() }

        let original = Data([0x10, 0x20, 0x30])
        try UserPortraitStorage.save(original)

        #expect(UserPortraitStorage.exists == true)
        #expect(UserPortraitStorage.load() == original)
    }

    @Test func savingAgainOverwritesRatherThanDuplicating() throws {
        UserPortraitStorage.delete()
        defer { UserPortraitStorage.delete() }

        try UserPortraitStorage.save(Data([0x01]))
        try UserPortraitStorage.save(Data([0x02]))

        #expect(UserPortraitStorage.load() == Data([0x02]))
    }

    @Test func deleteRemovesTheFile() throws {
        try UserPortraitStorage.save(Data([0x01]))
        UserPortraitStorage.delete()

        #expect(UserPortraitStorage.exists == false)
        #expect(UserPortraitStorage.load() == nil)
    }

    @Test func deletingWhenMissingDoesNotThrow() {
        UserPortraitStorage.delete()
        UserPortraitStorage.delete()
        #expect(UserPortraitStorage.exists == false)
    }
}
