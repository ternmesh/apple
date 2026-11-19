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

    func testAConversationAsText() {
        XCTAssertEqual(Peer.contact(Self.bob).key, "c:" + String(repeating: "b0", count: 32))
        XCTAssertEqual(Peer.group(Self.hut).key, "g:4848484848484848")
        for peer in [Peer.contact(Self.bob), .group(Self.hut)] {
            XCTAssertEqual(Peer(key: peer.key), peer)
        }
        XCTAssertNil(Peer(key: "g:" + String(repeating: "b0", count: 32)), "an address is not a group's id")
        XCTAssertNil(Peer(key: "c:4848484848484848"))
        XCTAssertNil(Peer(key: "x:4848484848484848"))
        XCTAssertNil(Peer(key: ""))
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

    // MARK: Names for routing ids

    /// The ids a node of version 13 or earlier gives, from the address itself: routing.md's, from
    /// vectors/routing.json in ternmesh/spec before announces carried a blinded key (spec#60).
    func testRoutingIds() {
        let ids: [(String, UInt32)] = [
            (String(repeating: "00", count: 32), 289_929_253),
            (String(repeating: "11", count: 32), 3_167_332_448),
            (String(repeating: "a5", count: 32), 1_399_809_041),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", 1_752_530_551),
        ]
        for (hex, id) in ids {
            XCTAssertEqual(Address(hex: hex)!.unblindedRoutingId, id, hex)
        }
        // The exchange in vectors/companion.json: a group message from the second address.
        let second = Address(hex: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")!
        XCTAssertEqual(second.unblindedRoutingId, 4_029_751_709)
    }

    func testAContactNamesItsRoutingId() {
        let r = records([
            .contact(Contact(address: Self.bob, session: 1, name: "Bob")),
            .contact(Contact(address: Self.carol, session: 0, name: "")),
        ])
        let names = r.routingNames
        XCTAssertEqual(names, [Self.bob.unblindedRoutingId: "Bob", Self.carol.unblindedRoutingId: "cacacaca…"])
        XCTAssertEqual(Words.sender(Self.bob.unblindedRoutingId, names: names), "Bob (claimed)", "a name is what the writer claimed")
        XCTAssertEqual(Words.sender(0x0A0B_0C0D, names: names), "0a0b0c0d", "an id no contact has stays an id")
        XCTAssertEqual(Words.sender(0, names: names), "You")
    }

    func testARoutingIdTwoContactsShareNamesNeither() {
        let names = Records.byRoutingId([(7, "Bob"), (9, "Dan"), (7, "Carol"), (7, "Eve"), (0, "Zero")])
        XCTAssertEqual(names, [9: "Dan"])
    }

    func testACardNamesARoutingIdNoContactHas() {
        let dan = Address([UInt8](repeating: 0xDA, count: 32))!
        let r = records([
            .contact(Contact(address: Self.bob, session: 1, name: "Bob")),
            .card(Card(address: Self.bob, heard: 30, name: "Robert")),
            .card(Card(address: Self.carol, heard: 60, name: "Carol")),
            .card(Card(address: dan, heard: 90, name: "")),
        ])
        let cards = r.routingCards
        XCTAssertEqual(cards.keys.sorted(), [Self.carol.unblindedRoutingId, dan.unblindedRoutingId].sorted())
        XCTAssertEqual(cards[Self.carol.unblindedRoutingId]?.name, "Carol")
        XCTAssertEqual(cards[dan.unblindedRoutingId]?.address, dan, "a card with no name still has its address")
        XCTAssertNil(cards[Self.bob.unblindedRoutingId], "a contact's own name comes before their card's")
        XCTAssertEqual(r.routingNames[Self.bob.unblindedRoutingId], "Bob")
    }

    func testARoutingIdTwoCardsShareNamesNeither() {
        let card = { (name: String) in Card(address: Self.carol, heard: 0, name: name) }
        let named: [(id: UInt32, name: Card)] = [(7, card("Carol")), (9, card("Dan")), (7, card("Eve"))]
        let cards = Records.byRoutingId(named)
        XCTAssertEqual(cards, [9: card("Dan")])
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

    /// A conversation seen behind another's unread item is read once that one is.
    func testAConversationSeenWaitsForTheOneBeforeIt() {
        let r = records([message(1, Self.carol), message(2, Self.bob), message(3, Self.bob)])
        let bob = Peer.contact(Self.bob), carol = Peer.contact(Self.carol)
        XCTAssertNil(r.readThrough(seen: [bob: 3]), "Carol's 1 is unread and unseen")
        XCTAssertEqual(r.readThrough(seen: [bob: 3, carol: 1]), 3, "both seen: all three")
        XCTAssertEqual(r.readThrough(seen: [bob: 2, carol: 1]), 2, "Bob's 3 came after he was seen")
    }

    func testSleepWords() {
        let keeper: UInt32 = 0x1D2E_3F40
        XCTAssertEqual(Words.sleep(Sleep(wake: 0, listen: 2, state: Sleep.awake, keeper: 0, retry: 0)), "Awake")
        XCTAssertEqual(
            Words.sleep(Sleep(wake: 600, listen: 4, state: Sleep.asleep, keeper: keeper, retry: 0)),
            "Asleep — kept by 1d2e3f40")
        XCTAssertEqual(
            Words.sleep(Sleep(wake: 600, listen: 4, state: Sleep.asleep, keeper: keeper, retry: 0), names: [keeper: "Hut"]),
            "Asleep — kept by Hut")
        XCTAssertEqual(
            Words.sleep(Sleep(wake: 600, listen: 2, state: Sleep.waiting, keeper: 0, retry: 0)),
            "Waiting for a relay to keep its messages")
        XCTAssertEqual(
            Words.sleep(Sleep(wake: 3600, listen: 2, state: Sleep.resting, keeper: 0xD82C_1E1A, retry: 3581)),
            "No relay answers; trying d82c1e1a again in 59 min")
        XCTAssertEqual(Words.wakes(900), "Sleeps, wakes every 15 min")
        XCTAssertEqual(Words.heldUntilWake(600), "Held by its relay until it wakes, within 10 min")
    }

    /// A `FORGOTTEN` takes the address's messages and invites through its id, whatever group an
    /// invite is to; a `GROUP_FORGOTTEN` the group's messages; and the conversations go with them.
    func testForgottenTakesTheConversationThroughItsId() {
        var r = records([
            message(1, Self.bob), invite(2, from: Self.bob, to: Self.hut), groupMessage(3, Self.hut),
            message(4, Self.carol), groupMessage(5, Self.ridge), message(6, Self.bob),
        ])
        r.apply(.forgotten(contact: Self.bob, through: 5))
        XCTAssertEqual(r.items.keys.sorted(), [3, 4, 5, 6])
        r.apply(.groupForgotten(group: Self.hut, through: 0xFFFF_FFFF))
        XCTAssertEqual(r.items.keys.sorted(), [4, 5, 6])
        r.apply(.forgotten(contact: Self.carol, through: 3))
        XCTAssertEqual(r.items.keys.sorted(), [4, 5, 6], "Carol's 4 came after")
        XCTAssertEqual(r.conversations.map(\.peer), [.contact(Self.bob), .group(Self.ridge), .contact(Self.carol)])
    }

    /// What forgetting would give up: a message or invite waiting or sent, a group message waiting.
    func testHasUnsent() {
        let sentToGroup = records([groupMessage(1, Self.hut, from: 0)])
        XCTAssertFalse(sentToGroup.conversation(with: .group(Self.hut)).hasUnsent)
        let sent = records([message(1, Self.bob, received: false)])
        XCTAssertTrue(sent.conversation(with: .contact(Self.bob)).hasUnsent)
        let received = records([message(1, Self.bob)])
        XCTAssertFalse(received.conversation(with: .contact(Self.bob)).hasUnsent)
    }

    func testForgetWords() {
        XCTAssertEqual(Words.forgetTitle("Bob"), "Delete chat with Bob?")
        XCTAssertEqual(
            Words.forgetWarning(group: false, unsent: false),
            "Every message and invite in this chat is erased from your node, and from every phone or computer "
                + "connected to it. This can't be undone. The contact and any secure session with them are kept.")
        XCTAssertEqual(
            Words.forgetWarning(group: true, unsent: true),
            "Every message in this group's chat is erased from your node, and from every phone or computer "
                + "connected to it. This can't be undone. You stay in the group. Messages not yet delivered won't be sent.")
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
