// SHA-256 against FIPS 180-4's examples, the release manifest and the image in it for a node, and
// Semantic Versioning's order.

import Foundation
import XCTest

@testable import TernKit

final class ReleaseTests: XCTestCase {
    // MARK: SHA-256

    func testSHA256AgainstFIPS180() {
        let cases: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
             "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
        ]
        for (text, digest) in cases {
            XCTAssertEqual(SHA256.hash(Array(text.utf8)).description, digest, text)
        }
        XCTAssertEqual(
            SHA256.hash([UInt8](repeating: 0x61, count: 1_000_000)).description,
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Fed in pieces of any size, the digest is the same as all at once, across every block edge.
    func testSHA256InPieces() {
        let bytes = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        for n in [0, 1, 55, 56, 63, 64, 65, 119, 128, 300] {
            let whole = SHA256.hash(Array(bytes[0..<n]))
            for piece in [1, 3, 63, 64, 100] {
                var s = SHA256()
                var at = 0
                while at < n {
                    s.update(Array(bytes[at..<min(at + piece, n)]))
                    at += piece
                }
                XCTAssertEqual(s.finish(), whole, "\(n) bytes in pieces of \(piece)")
            }
        }
    }

    // MARK: The manifest

    static let manifest = """
        {"release":"0.2.0","images":[
          {"board":"heltec-v3","region":"EU868","file":"tern-heltec-v3-eu868-0.2.0-app.bin","size":1048576,
           "sha256":"5bfba1ba423a18ae5da63853d4ece421507db90702b63dcc6ebdac56b5ce4349"},
          {"board":"heltec-v3","region":"US915","file":"tern-heltec-v3-us915-0.2.0-app.bin","size":1048000,
           "sha256":"E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"},
          {"board":"rak4631","region":"EU868","file":"tern-rak4631-eu868-0.2.0-app.bin","size":400,
           "sha256":"5bfba1ba423a18ae5da63853d4ece421507db90702b63dcc6ebdac56b5ce4349", "notes": [1, 2.5e1, null, true, "\\u00e9\\ud83d\\ude00"]}
        ]}
        """

    func testTheImageForABoardAndRegion() throws {
        let m = try FirmwareManifest(json: Array(Self.manifest.utf8))
        XCTAssertEqual(m.release, "0.2.0")
        XCTAssertEqual(m.images.count, 3)
        let image = try XCTUnwrap(m.image(board: "heltec-v3", region: "eu868"))
        XCTAssertEqual(image.file, "tern-heltec-v3-eu868-0.2.0-app.bin")
        XCTAssertEqual(image.size, 1_048_576)
        XCTAssertEqual(image.url, "https://ternmesh.org/firmware/tern-heltec-v3-eu868-0.2.0-app.bin")
        XCTAssertEqual(m.image(board: "HELTEC-V3", region: "US915")?.size, 1_048_000)
        XCTAssertNil(m.image(board: "heltec-v3", region: "AU915"))
        XCTAssertNil(m.image(board: "", region: "EU868"), "an empty board is a node that cannot be updated this way")
        XCTAssertNil(m.image(board: "rak4631", region: ""), "nor is there an image for no region")
    }

    func testAnImageMatchesItsSizeAndDigest() throws {
        let m = try FirmwareManifest(json: Array(Self.manifest.utf8))
        let rak = try XCTUnwrap(m.image(board: "rak4631", region: "EU868"))
        let image = CompanionVectorTests.vectors["image"]!.bytes
        XCTAssertTrue(rak.matches(image))
        XCTAssertFalse(rak.matches(image.dropLast() + [0]))
        XCTAssertFalse(rak.matches(image + [0]))
    }

    func testAManifestThatIsNotOneIsRefused() {
        func read(_ s: String) -> FirmwareManifest.ReadError? {
            do {
                _ = try FirmwareManifest(json: Array(s.utf8))
                return nil
            } catch {
                return error as? FirmwareManifest.ReadError
            }
        }
        let digest = String(repeating: "ab", count: 32)
        func one(_ fields: String) -> String { #"{"release":"1.0.0","images":[{\#(fields)}]}"# }
        let good = #""board":"b","region":"EU868","file":"f.bin","size":10,"sha256":"\#(digest)""#
        XCTAssertNil(read(one(good)))
        XCTAssertEqual(read(""), .notJSON)
        XCTAssertEqual(read("{"), .notJSON)
        XCTAssertEqual(read(#"{"release":"1.0.0","images":[]} x"#), .notJSON)
        XCTAssertEqual(read(#"{"release":"v1.0.0","images":[]}"#), .bad(field: "release"))
        XCTAssertEqual(read(#"{"release":"1.0.0"}"#), .bad(field: "images"))
        XCTAssertEqual(read(one(good.replacingOccurrences(of: "f.bin", with: "../f.bin"))), .bad(field: "file"))
        XCTAssertEqual(read(one(good.replacingOccurrences(of: "f.bin", with: "https://elsewhere/f.bin"))), .bad(field: "file"))
        XCTAssertEqual(read(one(good.replacingOccurrences(of: "10", with: "0"))), .bad(field: "size"))
        XCTAssertEqual(read(one(good.replacingOccurrences(of: "10", with: "1.5"))), .bad(field: "size"))
        XCTAssertEqual(read(one(good.replacingOccurrences(of: digest, with: "ab"))), .bad(field: "sha256"))
        XCTAssertEqual(read(one(good.replacingOccurrences(of: #""board":"b","#, with: ""))), .bad(field: "board"))
    }

    func testJSONStrings() throws {
        XCTAssertEqual(try JSONValue.parse(Array(#""a\"\\\/\né😀""#.utf8)), .string("a\"\\/\né😀"))
        XCTAssertThrowsError(try JSONValue.parse(Array(#""\ud83d""#.utf8)), "a lone surrogate")
        XCTAssertThrowsError(try JSONValue.parse([0x22, 0xC3, 0x28, 0x22]), "not UTF-8")
        XCTAssertThrowsError(try JSONValue.parse(Array("[01]".utf8)))
        XCTAssertEqual(try JSONValue.parse(Array(" [-0.5e1, {}] ".utf8)), .array([.number(-5), .object([:])]))
    }

    // MARK: Semantic Versioning

    /// Semantic Versioning 2.0.0's own example of precedence, in order, and a few more.
    func testSemverPrecedence() {
        let ordered = [
            "0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
            "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0",
        ].map { SemanticVersion($0)! }
        for i in ordered.indices {
            for j in ordered.indices {
                XCTAssertEqual(ordered[i] < ordered[j], i < j, "\(ordered[i]) < \(ordered[j])")
            }
        }
        XCTAssertEqual(SemanticVersion("1.0.0+build.5"), SemanticVersion("1.0.0"), "build metadata does not count")
        XCTAssertEqual(SemanticVersion("1.0.0-rc.1+x")?.description, "1.0.0-rc.1+x")
    }

    func testSemverRefusesWhatIsNotOne() {
        for s in ["", "1", "1.0", "v1.0.0", "1.0.0.0", "01.0.0", "1.0.0-", "1.0.0-01", "1.0.0-a..b", "1.0.0+", "1.0.0-a_b", " 1.0.0", "1.-1.0"] {
            XCTAssertNil(SemanticVersion(s), s)
        }
        XCTAssertNotNil(SemanticVersion("1.0.0-0a.010a+001"), "identifiers with letters may start with 0, and so may build metadata")
    }

    func testAReleaseAgainstTheOneANodeRuns() throws {
        let m = try FirmwareManifest(json: Array(Self.manifest.utf8))
        XCTAssertEqual(m.compared(to: "0.1.9"), .newer)
        XCTAssertEqual(m.compared(to: "0.2.0-rc.1"), .newer)
        XCTAssertEqual(m.compared(to: "0.2.0"), .same)
        XCTAssertEqual(m.compared(to: "0.2.0+local"), .same)
        XCTAssertEqual(m.compared(to: "0.10.0"), .older)
        XCTAssertEqual(m.compared(to: ""), .unknown, "a build made by hand has no release")
    }
}
