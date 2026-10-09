// Sharing against the specification's vectors (vectors/sharing.json here, a copy of
// vectors/sharing.json in ternmesh/spec): its conformance section, but for the not-contacts cases,
// which the node refuses (a contact it is given must be a valid address) and so are tested there.

import Foundation
import XCTest

@testable import TernKit

final class SharingVectorTests: XCTestCase {
    static let vectors: [String: JSON] = {
        let url = Bundle.module.url(forResource: "sharing", withExtension: "json", subdirectory: "vectors")!
        let data = try! Data(contentsOf: url)
        guard case let .object(o) = try! JSONDecoder().decode(JSON.self, from: data) else { fatalError() }
        return o
    }()

    var v: [String: JSON] { Self.vectors }

    func testCasesShownAndRead() {
        let cases = v["cases"]!.array
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let a = Address(c["address"]!.bytes)!
            XCTAssertEqual(Sharing.text(a), c["text"]!.string)
            XCTAssertEqual(Sharing.link(a), c["link"]!.string)
            XCTAssertTrue(Sharing.link(a).hasSuffix(c["base32"]!.string))
            XCTAssertEqual(Sharing.shortCode(a), c["short_code"]!.string)
            XCTAssertEqual(Sharing.read(Sharing.grouped(a)), a)
            for r in c["reads"]!.array { XCTAssertEqual(Sharing.read(r.string), a, r.string) }
        }
    }

    func testRefusedReadsNothing() {
        for r in v["refused"]!.array { XCTAssertNil(Sharing.read(r.string), r.string) }
    }

    func testNotContactsStillRead() {
        for c in v["not_contacts"]!.array { XCTAssertNotNil(Sharing.read(c["link"]!.string), c["reason"]!.string) }
    }

    func testShortCodeForms() {
        for c in v["short_code_forms"]!.array { XCTAssertEqual(Sharing.format(UInt64(c["value"]!.int)), c["text"]!.string) }
    }

    func testSHA256() {
        XCTAssertEqual(Hex.encode(SHA256.hash([]).bytes), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hex.encode(SHA256.hash(Array("abc".utf8)).bytes), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Hex.encode(SHA256.hash(Array(repeating: UInt8(ascii: "a"), count: 1000)).bytes),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}
