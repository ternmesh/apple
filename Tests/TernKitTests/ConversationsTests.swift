// The records grouped as a person reads them, and the READ that marks only what was seen.

import XCTest

@testable import TernKit

final class ConversationsTests: XCTestCase {
    static let bob = Address([UInt8](repeating: 0xB0, count: 32))!
    static let carol = Address([UInt8](repeating: 0xCA, count: 32))!
    static let hut = GroupID([UInt8](repeating: 0x48, count: 8))!
    static let ridge = GroupID([UInt8](repeating: 0x52, count: 8))!

    private func message(_ id: UInt32, _ to: Address, received: Bool = true, read: Bool = false) -> Body {
        .message(Message(
            id: id, contact: to, time: 1000 + id, flags: read ? 1 : 0,
            state: received ? MessageState.received : MessageState.sent, reason: 0, wait: 0, text: "m\(id)"))
    }

    private func groupMessage(_ id: UInt32, _ group: GroupID, from: UInt32 = 7, read: Bool = false) -> Body {
        .groupMessage(GroupMessage(
            id: id, group: group, from: from, time: 0, flags: read ? 1 : 0,
            state: from == 0 ? MessageState.sent : MessageState.received, reason: 0, wait: 0, text: "g\(id)"))
    }

    private func invite(_ id: UInt32, from: Address, to group: GroupID) -> Body {
        .invite(Invite(
            id: id, contact: from, group: group, time: 0, flags: 0, state: MessageState.received, reason: 0,
            wait: 0, name: "Ridge"))
    }

    private func records(_ news: [Body]) -> Records {
        var r = Records()
        for n in news { r.apply(n) }
        return r
    }

    // MARK: Conversations

    func testOneConversationPerAddressAndPerGroupLatestFirst() {
        let r = records([
            .contact(Contact(address: Self.bob, session: 1, name: "Bob")),
            .group(Group(group: Self.hut, name: "Hut")),
            .group(Group(group: Self.ridge, name: "")),
            message(1, Self.bob, received: false),
            message(2, Self.carol),
            message(3, Self.bob),
            invite(4, from: Self.carol, to: Self.ridge),
        ])
        let c = r.conversations
        XCTAssertEqual(c.map(\.peer), [.contact(Self.carol), .contact(Self.bob), .group(Self.ridge), .group(Self.hut)])
        XCTAssertEqual(c.map(\.name), ["cacacaca…", "Bob", "52525252…", "Hut"])
        XCTAssertEqual(c[0].items.map(\.id), [2, 4], "the invite sits with whom it came from")
        XCTAssertEqual(c[0].unread, 2)
        XCTAssertEqual(c[1].items.map(\.id), [1, 3])
        XCTAssertEqual(c[1].unread, 1, "a sent message is never unread")
        XCTAssertEqual(c[3].items, [], "a group held with nothing in it yet is a conversation")
        XCTAssertEqual(c[0].last?.summary, "Invite to Ridge")
    }

    func testAGroupLeftKeepsItsMessages() {
        let r = records([groupMessage(5, Self.hut, from: 0)])
        XCTAssertEqual(r.conversations.map(\.peer), [.group(Self.hut)])
        XCTAssertEqual(r.conversations[0].name, "48484848…")
        XCTAssertEqual(r.conversation(with: .group(Self.hut)).items.map(\.id), [5])
    }

    // MARK: READ

    func testReadThroughEverythingHereWhenNothingElseIsUnread() {
        let r = records([message(1, Self.bob), message(2, Self.bob), message(3, Self.carol, read: true)])
        XCTAssertEqual(r.readThrough(showing: .contact(Self.bob)), 2)
        XCTAssertNil(r.readThrough(showing: .contact(Self.carol)), "nothing unread there")
    }

    func testReadStopsShortOfWhatIsUnreadElsewhere() {
        let r = records([
            message(1, Self.bob), message(2, Self.bob),
            groupMessage(3, Self.hut),
            message(4, Self.bob),
        ])
        XCTAssertEqual(r.readThrough(showing: .contact(Self.bob)), 2, "not through 4: that would mark 3")
        XCTAssertNil(r.readThrough(showing: .group(Self.hut)), "3 cannot be marked without 1 and 2")
    }

    func testReadAfterWhatIsUnreadElsewhere() {
        let r = records([message(1, Self.carol), message(5, Self.bob), message(6, Self.bob)])
        XCTAssertNil(r.readThrough(showing: .contact(Self.bob)))
        XCTAssertEqual(r.readThrough(showing: .contact(Self.carol)), 1)
        // Once Carol's is read, Bob's can be.
        var after = r
        after.apply(message(1, Self.carol, read: true))
        XCTAssertEqual(after.readThrough(showing: .contact(Self.bob)), 6)
    }

    func testSentItemsDoNotHoldReadBack() {
        let r = records([message(1, Self.bob), message(2, Self.carol, received: false), message(3, Self.bob)])
        XCTAssertEqual(r.readThrough(showing: .contact(Self.bob)), 3)
    }

    // MARK: What to tell the user of

    func testAnArrivalIsReceivedUnreadAndNew() {
        let r = records([message(1, Self.bob)])
        XCTAssertFalse(r.isArrival(message(1, Self.bob)), "held already: a sync sends it again")
        XCTAssertTrue(r.isArrival(message(2, Self.bob)))
        XCTAssertTrue(r.isArrival(groupMessage(3, Self.hut)))
        XCTAssertTrue(r.isArrival(invite(4, from: Self.carol, to: Self.hut)))
        XCTAssertFalse(r.isArrival(message(5, Self.bob, read: true)), "read on another client")
        XCTAssertFalse(r.isArrival(message(6, Self.bob, received: false)), "the user's own")
        XCTAssertFalse(r.isArrival(groupMessage(7, Self.hut, from: 0)))
        XCTAssertFalse(r.isArrival(.power(Power(millivolts: 0, percent: 255, flags: 0))))
    }

    // MARK: Words

    /// An unanswered send that reached the node is found in a sync, and not sent again.
    func testASendTheNodeHoldsIsFound() {
        let r = records([message(4, Self.bob, received: false), message(5, Self.carol), groupMessage(6, Self.hut, from: 0)])
        XCTAssertTrue(r.holdsSent("m4", to: .contact(Self.bob), after: 3))
        XCTAssertFalse(r.holdsSent("m4", to: .contact(Self.bob), after: 4), "written before the send")
        XCTAssertFalse(r.holdsSent("m4", to: .contact(Self.carol), after: 3), "to someone else")
        XCTAssertFalse(r.holdsSent("m5", to: .contact(Self.carol), after: 3), "received, not sent")
        XCTAssertTrue(r.holdsSent("g6", to: .group(Self.hut), after: 0))
    }

    func testWords() {
        XCTAssertEqual(Words.waiting(reason: 0, wait: 0), "Waiting")
        XCTAssertEqual(Words.waiting(reason: 1, wait: 0), "Waiting: looking for a route")
        XCTAssertEqual(Words.waiting(reason: 3, wait: 150), "Waiting: the region's transmit limit, about 2 min")
        XCTAssertEqual(Words.waiting(reason: 0, wait: 45), "Waiting, about 45 s")
        XCTAssertEqual(Words.state(MessageState.notDelivered), "Not delivered")
        XCTAssertEqual(Words.sender(0), "You")
        XCTAssertEqual(Words.sender(0x0A0B_0C0D), "0a0b0c0d")
        XCTAssertEqual(Words.snr(-7), "-1.75 dB")
        XCTAssertEqual(Words.snr(40), "10 dB")
        XCTAssertEqual(Words.error(ErrorCode.mtu), "The Bluetooth link is too small for the node's frames.")
        XCTAssertEqual(Words.error(200), "The node refused (200).")
        XCTAssertEqual(Words.textBytes("é"), 2)
    }
}
