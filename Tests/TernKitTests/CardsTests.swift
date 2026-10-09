// Who is about as a person reads it: the cards held in the order a list shows them, how long ago
// each was heard counting on from its record, and the name a node's cards may carry.

import XCTest

@testable import TernKit

final class CardsTests: XCTestCase {
    static let ann = Address([UInt8](repeating: 0xA0, count: 32))!
    static let bob = Address([UInt8](repeating: 0xB0, count: 32))!
    static let cy = Address([UInt8](repeating: 0xC0, count: 32))!

    private func records(_ news: [Body]) -> Records {
        var r = Records()
        for n in news { r.apply(n) }
        return r
    }

    func testTheMostRecentlyHeardFirst() {
        let r = records([
            .card(Card(address: Self.ann, heard: 600, name: "Ann")),
            .card(Card(address: Self.bob, heard: 30, name: "Bob")),
            .card(Card(address: Self.cy, heard: 7200, name: "")),
        ])
        XCTAssertEqual(r.cardsHeard().map(\.address), [Self.bob, Self.ann, Self.cy])
    }

    func testHeardCountsOnFromEachRecord() {
        // Bob's record came 1000 seconds ago and Ann's just now: Bob was heard longer ago, though
        // his record said less.
        let r = records([
            .card(Card(address: Self.ann, heard: 600, name: "Ann")),
            .card(Card(address: Self.bob, heard: 30, name: "Bob")),
        ])
        let shown = r.cardsHeard(since: { $0 == Self.bob ? 1000 : 0 })
        XCTAssertEqual(shown.map(\.address), [Self.ann, Self.bob])
        XCTAssertEqual(shown.map(\.heard), [600, 1030])
    }

    func testHeardAsLongAgoIsInOrderOfNameThenAddress() {
        let r = records([
            .card(Card(address: Self.cy, heard: 60, name: "Ann")),
            .card(Card(address: Self.bob, heard: 60, name: "Zed")),
            .card(Card(address: Self.ann, heard: 60, name: "Ann")),
        ])
        XCTAssertEqual(r.cardsHeard().map(\.address), [Self.ann, Self.cy, Self.bob])
    }

    func testCountingOnStopsAtTheLargestItCanSay() {
        let c = Card(address: Self.ann, heard: .max - 5, name: "")
        XCTAssertEqual(c.later(by: 10).heard, .max)
        XCTAssertEqual(c.later(by: 5).heard, .max)
        XCTAssertEqual(Card(address: Self.ann, heard: 5, name: "").later(by: 10).heard, 15)
    }

    func testACardIsNotAContactsName() {
        // Saving the card's sender under another name: the card keeps its claim, and the contact
        // its name.
        let r = records([
            .card(Card(address: Self.ann, heard: 0, name: "Trail crew")),
            .contact(Contact(address: Self.ann, session: 0, name: "Ann")),
        ])
        XCTAssertTrue(r.isContact(Self.ann))
        XCTAssertFalse(r.isContact(Self.bob))
        XCTAssertEqual(r.name(of: .contact(Self.ann)), "Ann")
        XCTAssertEqual(r.cardsHeard().first?.name, "Trail crew")
    }

    func testACardNameIsAtMost31BytesOfUTF8() {
        XCTAssertTrue(Card.fits(""))
        XCTAssertTrue(Card.fits(String(repeating: "a", count: 31)))
        XCTAssertFalse(Card.fits(String(repeating: "a", count: 32)))
        // Ten characters of three bytes each, and one more of two: 32 bytes in 11 characters.
        XCTAssertTrue(Card.fits(String(repeating: "€", count: 10)))
        XCTAssertFalse(Card.fits(String(repeating: "€", count: 10) + "é"))
        // What the codec takes, the check takes, and the other way round.
        for name in ["", String(repeating: "a", count: 31), String(repeating: "€", count: 10) + "é"] {
            let encoded = try? Frame(seq: 1, body: .set(.cardName(name))).encode()
            XCTAssertEqual(encoded != nil, Card.fits(name), name)
        }
    }

    func testWords() {
        XCTAssertEqual(Words.cardName("Ann"), "“Ann”")
        XCTAssertEqual(Words.cardName(""), "No name")
        XCTAssertEqual(Words.claim("Ann"), "Says they are “Ann”")
        XCTAssertNil(Words.claim(""))
        XCTAssertEqual(Words.ago(0), "just now")
        XCTAssertEqual(Words.ago(59), "just now")
        XCTAssertEqual(Words.ago(60), "1 min ago")
        XCTAssertEqual(Words.ago(7200), "2 h ago")
    }
}
