import Foundation
import XCTest
@testable import Debattle

final class SolanaReceiptTests: XCTestCase {
    private func fixture(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "schema": "debattle-proof-v1", "cluster": "devnet",
            "signature": String(repeating: "2", count: 88),
            "signer": String(repeating: "3", count: 44),
            "digest": String(repeating: "a", count: 64),
            "memo": "debattle-proof-v1:" + String(repeating: "a", count: 64),
            "record": ["completion": ["turns": 2], "nonce": "test-salt", "futureField": ["enabled": true]],
            "explorerURL": "https://malicious.example/collect"
        ]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testExportPreservesEveryFieldWithoutReencodingTheRecord() throws {
        let original = try fixture()
        let receipt = try SolanaReceipt(data: original)
        XCTAssertEqual(receipt.data, original)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt.data) as? [String: Any])
        let record = try XCTUnwrap(decoded["record"] as? [String: Any])
        XCTAssertNotNil(record["futureField"], "Unknown fields must survive portable proof export.")
    }

    func testExplorerLinkIsDerivedFromValidatedSignatureNotServerSuppliedURL() throws {
        let receipt = try SolanaReceipt(data: fixture())
        XCTAssertEqual(receipt.explorerURL.host, "explorer.solana.com")
        XCTAssertEqual(receipt.explorerURL.query, "cluster=devnet")
        XCTAssertEqual(receipt.explorerURL.path, "/tx/" + receipt.signature)
    }

    func testMainnetMalformedHashAndPathInjectionAreRejectedBeforePresentation() throws {
        for invalid: [String: Any] in [
            ["cluster": "mainnet-beta"], ["schema": "unknown"],
            ["signature": "../?cluster=mainnet-beta"], ["signer": "not a wallet"],
            ["digest": "fake"], ["record": "not an object"]
        ] {
            XCTAssertThrowsError(try SolanaReceipt(data: fixture(invalid)))
        }
    }
}
