// Records written to the file and read back: the format the Android app shares.

import XCTest

@testable import TernKit

final class RecordsFileTests: XCTestCase {
    /// Records holding one of everything the vectors' news gives, and the exchange's.
    private func held() throws -> Records {
        var r = Records()
        let v = CompanionVectorTests.vectors
        for c in v["frames"]!.array + v["exchange"]!.array {
            let bytes = c["frame"]!.bytes
            guard bytes[0].isNewsType else { continue }
            r.apply(try Frame.decode(bytes).body)
        }
        return r
    }

    func testRecordsReadBackAsTheyWereWritten() throws {
        let r = try held()
        XCTAssertNotNil(r.me)
        XCTAssertFalse(r.contacts.isEmpty)
        XCTAssertFalse(r.groups.isEmpty)
        XCTAssertFalse(r.neighbours.isEmpty)
        XCTAssertNotNil(r.airtime)
        XCTAssertNotNil(r.power)
        XCTAssertFalse(r.routes.isEmpty)
        let kinds = Set(r.items.values.map { item -> Int in
            switch item {
            case .message: 0
            case .groupMessage: 1
            case .invite: 2
            }
        })
        XCTAssertEqual(kinds, [0, 1, 2])
        XCTAssertEqual(Records(decoding: r.encoded()), r.kept)
    }

    /// Positions and sharing count on from when they were sent, and every sync sends them whole:
    /// the file does not keep them, and one that does is read all the same.
    func testPositionsAndSharingAreNotKept() throws {
        let r = try held()
        XCTAssertFalse(r.positions.isEmpty)
        XCTAssertFalse(r.groupPositions.isEmpty)
        XCTAssertFalse(r.groupSharing.isEmpty)
        let back = Records(decoding: r.encoded())
        XCTAssertEqual(back.positions, [:])
        XCTAssertEqual(back.groupPositions, [:])
        XCTAssertEqual(back.sharing, [:])
        XCTAssertEqual(back.groupSharing, [:])
        XCTAssertEqual(r.encoded(), r.kept.encoded())

        let bob = Address([UInt8](repeating: 0xB0, count: 32))!
        let position = try Frame(seq: 0, body: .position(
            contact: bob, Position(precision: 16, lat: 1, lon: 2, altitude: Position.noAltitude, accuracy: 0, age: 9))).encode()
        let sharing = try Frame(seq: 0, body: .sharing(
            contact: bob, PositionSharing(precision: 20, fields: 0, interval: 900, minutes: 60))).encode()
        let file = r.encoded() + [UInt8(position.count)] + position + [UInt8(sharing.count)] + sharing
        XCTAssertEqual(Records(decoding: file), r.kept)
    }

    /// Nor are cards: how long ago one was heard counts on, and every sync sends them all.
    func testCardsAreNotKept() throws {
        var r = try held()
        let card = Card(address: Address([UInt8](repeating: 0xB0, count: 32))!, heard: 5, name: "B")
        r.apply(.card(card))
        XCTAssertEqual(r.cards.count, 1)
        XCTAssertEqual(Records(decoding: r.encoded()), r.kept)
        XCTAssertEqual(r.encoded(), r.kept.encoded())
        // A file that holds one all the same is read, and it is passed over.
        let entry = try Frame(seq: 0, body: .card(card)).encode()
        XCTAssertEqual(Records(decoding: r.encoded() + [UInt8(entry.count)] + entry), r.kept)
    }

    /// Nor is the node's own fix: its age counts on, and every sync of version 8 sends it.
    func testTheFixIsNotKept() throws {
        let r = try held()
        XCTAssertNotNil(r.fix)
        XCTAssertNil(Records(decoding: r.encoded()).fix)
        XCTAssertEqual(Records(decoding: r.encoded()), r.kept)
        let entry = try Frame(seq: 0, body: .fix(r.fix!)).encode()
        XCTAssertEqual(Records(decoding: r.encoded() + [UInt8(entry.count)] + entry), r.kept)
    }

    /// A file written when the client spoke version 10, as every one before version 11 was, holds
    /// a `SELF` without `pairing`: it is read with its cards and the most, and says nothing of
    /// pairing.
    func testASelfOfVersion10IsReadWithTheMost() throws {
        var r = try held().kept
        r.syncedVersion = 10
        r.me?.cards = 1
        r.me?.cardName = "Ada"
        r.me?.most = 1
        r.me?.pairing = nil
        r.me?.locked = nil
        let back = Records(decoding: r.encoded())
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.me?.cardName, "Ada")
        XCTAssertEqual(back.me?.most, 1)
        XCTAssertNil(back.me?.pairing)
    }

    /// A file written when the client spoke version 9, as every one before version 10 was, holds a
    /// `SELF` without `most`: it is read with its cards, and says nothing of the most.
    func testASelfOfVersion9IsReadWithItsCards() throws {
        var r = try held().kept
        r.syncedVersion = 9
        r.me?.cards = 1
        r.me?.cardName = "Ada"
        r.me?.most = nil
        r.me?.pairing = nil
        r.me?.locked = nil
        let back = Records(decoding: r.encoded())
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.me?.cards, 1)
        XCTAssertEqual(back.me?.cardName, "Ada")
        XCTAssertNil(back.me?.most)
    }

    /// A file written when the client spoke version 5, or kept from a node that does, holds a
    /// `SELF` without `cards` and `card_name`: it is read, and says nothing of cards.
    func testASelfOfVersion5IsRead() throws {
        var r = try held().kept
        r.syncedVersion = 5
        r.me?.cards = nil
        r.me?.cardName = nil
        r.me?.most = nil
        r.me?.pairing = nil
        r.me?.locked = nil
        let file = r.encoded()
        let me = try Frame(seq: 0, body: .nodeSelf(r.me!)).encode()
        XCTAssertEqual(Array(file[11..<12 + me.count]), [UInt8(me.count)] + me, "SELF is the first entry, and ends at time")
        XCTAssertThrowsError(try Frame.decode(me))
        let back = Records(decoding: file)
        XCTAssertEqual(back, r)
        XCTAssertNil(back.me?.cards)
        // The next sync asks again from 0, speaking version 6.
        XCTAssertEqual(back.after(version: 6), 0)
        // Only SELF is read so: another record cut short still spoils the file.
        XCTAssertEqual(Records(decoding: Array(file.prefix(11)) + [3, 0x81, 0, 0]), Records())
    }

    func testTheHeader() throws {
        var r = Records()
        XCTAssertEqual(r.encoded(), Array("TRNR".utf8) + [1, 0xFF, 0, 0, 0, 0, 0])
        r.syncedVersion = 3
        r.missedSince = 0x0102_0304
        XCTAssertEqual(r.encoded(), Array("TRNR".utf8) + [1, 3, 1, 1, 2, 3, 4])
        let back = Records(decoding: r.encoded())
        XCTAssertEqual(back.syncedVersion, 3)
        XCTAssertEqual(back.missedSince, 0x0102_0304)
        // A missedSince of 0 is one: nothing held when news was first missed.
        r.missedSince = 0
        XCTAssertEqual(Records(decoding: r.encoded()).missedSince, 0)
    }

    /// A node's sleeping is fleeting, as its fix is: `retry` counts down, and every sync sends it.
    /// A CONTACT from before version 15, without `wake`, reads as version 14's.
    func testSleepingIsNotKeptAndAContactWithoutWakeIsRead() throws {
        let r = try held()
        XCTAssertNotNil(r.sleep)
        XCTAssertNil(Records(decoding: r.encoded()).sleep)
        let bob = Address([UInt8](repeating: 0xB0, count: 32))!
        let old = try Frame(seq: 0, body: .contact(Contact(address: bob, session: 1, name: "Bob"))).encode()
        var empty = Records()
        empty.syncedVersion = 14
        let file = empty.encoded() + [UInt8(old.count)] + old
        XCTAssertEqual(Records(decoding: file).contacts[bob], Contact(address: bob, session: 1, name: "Bob"))
    }

    /// A CONTACT and a SELF of version 16, without `owner` and `locked`, read as version 16's; and
    /// the owner and the lock are kept.
    func testAContactAndASelfOfVersion16AreRead() throws {
        let bob = Address([UInt8](repeating: 0xB0, count: 32))!
        let contact = Contact(address: bob, session: 1, name: "Bob", wake: 600)
        let me = NodeSelf(
            address: Address([UInt8](repeating: 0xAD, count: 32))!, role: 1, region: "EU868", power: 14, time: 0,
            cards: 0, cardName: "", most: 0, pairing: 1)
        var empty = Records()
        empty.syncedVersion = 16
        var file = empty.encoded()
        for body in [Body.nodeSelf(me), .contact(contact)] {
            let old = try Frame(seq: 0, body: body).encode()
            file += [UInt8(old.count)] + old
        }
        let read = Records(decoding: file)
        XCTAssertEqual(read.contacts[bob], contact)
        XCTAssertEqual(read.me, me)

        var r = Records()
        var owner = contact
        owner.owner = 1
        var locked = me
        locked.locked = 1
        r.apply(.contact(owner))
        r.apply(.nodeSelf(locked))
        let back = Records(decoding: r.encoded())
        XCTAssertEqual(back.contacts[bob]?.owner, 1)
        XCTAssertEqual(back.me?.locked, 1)
    }

    func testWhatWasMissedAndTheVersionAreKept() throws {
        var r = try held()
        r.syncedVersion = 2
        r.missedSince = 19
        let back = Records(decoding: r.encoded())
        XCTAssertEqual(back, r.kept)
        XCTAssertEqual(back.after(version: 2), r.after(version: 2))
    }

    func testAnEntryIsALengthThenAFrameWithSeq0() throws {
        var r = Records()
        r.power = Power(millivolts: 3900, percent: 80, flags: 1)
        let frame = try Frame(seq: 0, body: .power(r.power!)).encode()
        XCTAssertEqual(Array(r.encoded().dropFirst(11)), [UInt8(frame.count)] + frame)
    }

    func testAFileOfVersion4IsRead() throws {
        var r = try held().kept
        r.syncedVersion = 4
        var file = r.encoded()
        XCTAssertEqual(file[5], 4)
        XCTAssertEqual(Records(decoding: file), r)
        // And the next sync asks again from 0, for the kinds of record version 4 was not sent.
        XCTAssertEqual(Records(decoding: file).after(version: 5), 0)
        file[5] = 5
        XCTAssertNotEqual(Records(decoding: file).after(version: 5), 0)
    }

    /// How each message went is kept (version 18), the last `ROUTE` for each, after the messages; a
    /// `FORGOTTEN` takes the routes of what it forgets; and a file with a `TRACED` in it, which is
    /// not a record, is spoiled.
    func testRoutesAreKeptAndForgottenWithTheirMessages() throws {
        let alice = Address([UInt8](repeating: 0xA1, count: 32))!
        let bob = Address([UInt8](repeating: 0xB0, count: 32))!
        func received(_ id: UInt32, _ from: Address) -> Body {
            .message(Message(id: id, contact: from, time: 0, flags: 0, state: MessageState.received, reason: 0, wait: 0, text: "x"))
        }
        var r = Records()
        r.apply(received(40, alice))
        r.apply(received(41, bob))
        r.apply(.route(Route(id: 40, hops: 1, snr: 25, rssi: -71, via: 0, goes: 0, took: 0)))
        r.apply(.route(Route(id: 41, hops: 3, snr: -38, rssi: -112, via: 0, goes: 0, took: 0)))
        r.apply(.route(Route(id: 41, hops: 2, snr: -30, rssi: -110, via: 0, goes: 0, took: 0)))
        r.syncedVersion = Companion.version
        XCTAssertEqual(r.routes[41]?.hops, 2, "the last replaces the one before")
        XCTAssertEqual(Records(decoding: r.encoded()), r)
        // After the messages, before anything else: as the Android app writes them.
        let file = r.encoded()
        let types = sequence(state: 11) { at -> UInt8? in
            guard at < file.count else { return nil }
            defer { at += 1 + Int(file[at]) }
            return file[at + 1]
        }
        XCTAssertEqual(Array(types), [0x83, 0x83, 0x9A, 0x9A])
        r.apply(.forgotten(contact: alice, through: 40))
        XCTAssertEqual(Array(r.routes.keys), [41])
        let traced = try Frame(seq: 0, body: .traced(Traced(id: 42, to: 1, result: Traced.notBegun, out: 0, took: 0, snr: 0, entries: []))).encode()
        XCTAssertEqual(Records(decoding: r.encoded() + [UInt8(traced.count)] + traced), Records())
    }

    func testAnythingSpoiledReadsAsNothingHeld() throws {
        let good = try held().encoded()
        XCTAssertEqual(Records(decoding: []), Records())
        XCTAssertEqual(Records(decoding: Array(good.prefix(10))), Records())
        var magic = good
        magic[0] = UInt8(ascii: "X")
        XCTAssertEqual(Records(decoding: magic), Records(), "not the magic")
        var format = good
        format[4] = 2
        XCTAssertEqual(Records(decoding: format), Records(), "a format this app does not know")
        XCTAssertEqual(Records(decoding: Array(good.dropLast())), Records(), "an entry cut short")
        var synced = good
        synced[5] = Companion.version + 1
        XCTAssertEqual(Records(decoding: synced), Records(), "synced at a version this client does not speak")
        var flag = good
        flag[6] = 2
        XCTAssertEqual(Records(decoding: flag), Records(), "a missed flag neither 0 nor 1")
        // A frame that reads but is not a record.
        let ok = try Frame(seq: 0, body: .ok).encode()
        XCTAssertEqual(Records(decoding: good + [UInt8(ok.count)] + ok), Records(), "not a record")
        let asked = try Frame(seq: 0, body: .asked(address: Address([UInt8](repeating: 7, count: 32))!, why: 1)).encode()
        XCTAssertEqual(Records(decoding: good + [UInt8(asked.count)] + asked), Records(), "news, but not a record")
        // A frame that does not read: a MESSAGE cut short inside its entry.
        XCTAssertEqual(Records(decoding: good + [3, 0x83, 0, 0]), Records(), "a frame that does not read")
    }
}

private extension Records {
    /// What the file keeps of these records.
    var kept: Records {
        var r = self
        r.positions = [:]
        r.groupPositions = [:]
        r.sharing = [:]
        r.groupSharing = [:]
        r.cards = [:]
        r.fix = nil
        r.sleep = nil
        return r
    }
}
