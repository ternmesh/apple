// Join codes against the specification's vectors (vectors/groups.json here, a copy of
// vectors/groups.json in ternmesh/spec): its join_codes and bad_join_codes, as a client that reads
// a code to say which group it is for; and companion.json's group_ids, the id it says.

import Foundation
import XCTest

@testable import TernKit

final class JoinCodeVectorTests: XCTestCase {
    static let vectors: [String: JSON] = {
        let url = Bundle.module.url(forResource: "groups", withExtension: "json", subdirectory: "vectors")!
        let data = try! Data(contentsOf: url)
        guard case let .object(o) = try! JSONDecoder().decode(JSON.self, from: data) else { fatalError() }
        return o
    }()

    var v: [String: JSON] { Self.vectors }

    func testGroupIDsFromTheirSecrets() {
        let cases = CompanionVectorTests.vectors["group_ids"]!.array
        XCTAssertFalse(cases.isEmpty)
        for c in cases { XCTAssertEqual(JoinCode.groupID(c["group_secret"]!.bytes), GroupID(c["group"]!.bytes)!) }
    }

    func testEveryJoinCodeReadsAsItsGroupAndNameHoweverItIsWritten() {
        let cases = v["join_codes"]!.array
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let code = JoinCode(group: JoinCode.groupID(c["group_secret"]!.bytes), name: c["name"]!.string)
            XCTAssertEqual(JoinCode.read(c["link"]!.string), code, c["link"]!.string)
            XCTAssertTrue((52 ... Companion.linkMax).contains(c["link"]!.string.utf8.count))
            for r in c["reads"]!.array { XCTAssertEqual(JoinCode.read(r.string), code, r.string) }
        }
    }

    func testAnythingElseIsNoJoinCode() {
        for c in v["bad_join_codes"]!.array { XCTAssertNil(JoinCode.read(c["link"]!.string), c["why"]!.string) }
        XCTAssertNil(JoinCode.read(""))
        XCTAssertNil(JoinCode.read(JoinCode.link))
        XCTAssertNil(JoinCode.read(v["join_codes"]!.array[0]["link"]!.string + " "))
        // A long s is S to a Unicode case mapping, and nothing to ASCII's.
        XCTAssertNotNil(JoinCode.read("https://ternmesh.org/g#ytcmjrgeytcmjrgeytcmjrgeyququ"))
        XCTAssertNil(JoinCode.read("httpſ://ternmesh.org/g#ytcmjrgeytcmjrgeytcmjrgeyququ"))
    }
}
