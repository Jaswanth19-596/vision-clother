//
//  CreditCatalogTests.swift
//  Vision_clotherTests
//
//  Pure-Domain tests for the display-only credit catalog
//  (`Domain/CreditPack.swift`) and the `IAPGrantResult` wire decode
//  (`Services/IAPVerificationService.swift`). The amounts here restate the
//  backend's `PRODUCT_GRANTS` table (`backend/functions/src/iap/products.ts`)
//  so hand-sync drift between the two fails a test instead of shipping a
//  mislabeled button.
//

import Foundation
import Testing
@testable import Vision_clother

struct CreditCatalogTests {
    @Test func everyPackRoundTripsThroughLookup() {
        for pack in CreditCatalog.all {
            #expect(CreditCatalog.pack(forProductID: pack.productID) == pack)
        }
    }

    @Test func unknownProductIDReturnsNil() {
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.bogus") == nil)
        #expect(CreditCatalog.pack(forProductID: "") == nil)
    }

    @Test func productIDsAreUnique() {
        #expect(Set(CreditCatalog.allProductIDs).count == CreditCatalog.all.count)
    }

    @Test func amountsMirrorBackendGrantTable() {
        // Must match backend/functions/src/iap/products.ts PRODUCT_GRANTS.
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.recs50")?.amount == 50)
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.recs50")?.creditType == .recommendation)
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.recs200")?.amount == 200)
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.recs200")?.creditType == .recommendation)
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.tryon10")?.amount == 10)
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.tryon10")?.creditType == .tryOn)
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.tryon40")?.amount == 40)
        #expect(CreditCatalog.pack(forProductID: "com.visionclother.credits.tryon40")?.creditType == .tryOn)
    }

    @Test func eachCreditTypeOffersExactlyTwoPacks() {
        for creditType in CreditType.allCases {
            #expect(CreditCatalog.packs(for: creditType).count == 2)
        }
    }

    @Test func grantResultDecodesBackendSuccessBody() throws {
        // Shape produced by backend/functions/src/routes/iapVerify.ts on a
        // fresh grant.
        let json = """
        {"granted": true, "creditType": "recommendation", "amount": 50, "newBalance": 88, "alreadyProcessed": false}
        """
        let result = try JSONDecoder().decode(IAPGrantResult.self, from: Data(json.utf8))
        #expect(result.granted)
        #expect(result.creditType == "recommendation")
        #expect(result.amount == 50)
        #expect(result.newBalance == 88)
        #expect(result.alreadyProcessed == false)
        #expect(result.reason == nil)
    }

    @Test func grantResultDecodesDuplicateAndRevokedBodies() throws {
        let duplicate = try JSONDecoder().decode(
            IAPGrantResult.self,
            from: Data(#"{"granted": true, "alreadyProcessed": true}"#.utf8)
        )
        #expect(duplicate.granted)
        #expect(duplicate.alreadyProcessed == true)
        #expect(duplicate.amount == nil)

        let revoked = try JSONDecoder().decode(
            IAPGrantResult.self,
            from: Data(#"{"granted": false, "reason": "revoked"}"#.utf8)
        )
        #expect(!revoked.granted)
        #expect(revoked.reason == "revoked")
    }
}
