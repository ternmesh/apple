// The QR encoder against codes made with segno (vectors/qr.json, a copy of tests/vectors/qr.json in
// ternmesh/site), module for module, each at the mask segno was given; and the segments a join
// code's link is written in.

import Foundation
import XCTest

@testable import TernKit

final class QRTests: XCTestCase {
    static let vectors: [String: JSON] = {
        let url = Bundle.module.url(forResource: "qr", withExtension: "json", subdirectory: "vectors")!
        let data = try! Data(contentsOf: url)
        guard case let .object(o) = try! JSONDecoder().decode(JSON.self, from: data) else { fatalError() }
        return o
    }()

    private func rows(_ m: [[Bool]]) -> [String] { m.map { String($0.map { $0 ? "1" : "0" }) } }

    func testEachCodeIsTheReferencesModuleForModule() throws {
        let cases = Self.vectors["cases"]!.array
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let segments = c["segments"]!.array.map { QR.Segment(QR.Mode(rawValue: $0["mode"]!.string)!, $0["text"]!.string) }
            let m = try QR.encode(segments, mask: c["mask"]!.int)
            XCTAssertEqual(m.count, 17 + 4 * c["version"]!.int, segments[0].text)
            XCTAssertEqual(rows(m), c["modules"]!.array.map(\.string), segments[0].text)
        }
    }

    func testAJoinCodesLinkIsAlphanumericButForItsHashAndFitsVersion4AtMost() throws {
        let longest = JoinCode.link + String(repeating: "A", count: 79)
        XCTAssertEqual(QR.segments(longest).map(\.mode), [.alphanumeric, .byte, .alphanumeric])
        XCTAssertEqual(try QR.encode(QR.segments(longest)).count, 33)
        // A name of 12 bytes or fewer, a link of 71 characters or fewer, fits version 3.
        XCTAssertEqual(try QR.encode(QR.segments(String(longest.prefix(23 + 48)))).count, 29)
        // An address's link is one alphanumeric segment, in version 3.
        let address = Sharing.link(Address([UInt8](repeating: 0xAB, count: 32))!)
        XCTAssertEqual(QR.segments(address), [QR.Segment(.alphanumeric, address)])
        XCTAssertEqual(try QR.encode(QR.segments(address)).count, 29)
        // Text that is not alphanumeric goes as bytes.
        XCTAssertEqual(QR.segments("https://ternmesh.org/g#x"), [QR.Segment(.byte, "https://ternmesh.org/g#x")])
    }

    func testAMaskIsAlwaysChosenAndTheCodeIsTheSameEachTime() throws {
        let segments = QR.segments(JoinCode.link + "YTCMJRGEYTCMJRGEYTCMJRGEYQUQU")
        XCTAssertEqual(try QR.encode(segments), try QR.encode(segments))
        XCTAssertThrowsError(try QR.encode([QR.Segment(.byte, String(repeating: "x", count: 200))]))
        XCTAssertThrowsError(try QR.encode([QR.Segment(.alphanumeric, "lower")]))
    }
}
