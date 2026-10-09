// The connection, as the client in the specification's exchanges, and its timers and recovery
// against a node played by hand.

import XCTest

@testable import TernKit

final class ConnectionTests: XCTestCase {
    var v: [String: JSON] { CompanionVectorTests.vectors }

    // MARK: The specification's connections, from the client's side

    /// The client sends the exchange's frames, byte for byte, each only once the one before it is
    /// answered, and ends holding what the node's news said.
    func testExchange() throws {
        let frames = v["exchange"]!.array
        let setTime = try XCTUnwrap(frames.first { $0["type"]!.string == "SET_TIME" })
        guard case let .setTime(time) = try Frame.decode(setTime["frame"]!.bytes).body else { return XCTFail() }

        let link = Link(Connection(now: { 0 }, wallTime: { time }))
        let answers = link.replay(frames)

        XCTAssertEqual(answers.count, 11)
        XCTAssertEqual(answers.compactMap { try? $0.get() }.count, 11, "every request answered")
        let r = link.connection.records
        XCTAssertEqual(r.me?.region, "EU868")
        XCTAssertEqual(r.syncedVersion, Companion.version)
        XCTAssertEqual(r.contacts.values.map(\.name).sorted(), ["Bob", "Carol"])
        XCTAssertEqual(r.contacts.values.map(\.session), [0, 0], "Bob's session ended; Carol never had one")
        XCTAssertEqual(r.groups.values.map(\.name), ["Ridge walkers"], "the group made was left, the one joined renamed")
        XCTAssertEqual(r.items.keys.sorted(), Array(17...22))
        XCTAssertEqual(r.ordered.filter(\.isUnread), [], "READ marked the message, group message and invite read")
        XCTAssertEqual(r.items[18]?.state, MessageState.delivered)
        XCTAssertEqual(r.items[20]?.state, MessageState.sent)
        XCTAssertEqual(r.neighbours.count, 1)
        XCTAssertEqual(link.events.filter { if case .news(.asked) = $0 { true } else { false } }.count, 1)
    }

    /// A client of version 0 that holds messages through 17 asks only for those after them, and
    /// sets no clock when it has none to give.
    func testOlderVersion0() throws {
        let older = v["older"]!.array.first { $0["version"]!.int == 0 }!
        var held = Records()
        held.items[17] = .message(Message(
            id: 17, contact: Address([UInt8](repeating: 1, count: 32))!, time: 0, flags: 1,
            state: MessageState.received, reason: 0, wait: 0, text: "x"))
        held.syncedVersion = 0
        let link = Link(Connection(version: 0, records: held, now: { 0 }, wallTime: nil))
        let answers = link.replay(older["frames"]!.array)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(link.connection.agreed, 0)
        XCTAssertEqual(link.connection.records.contacts.count, 2)
    }

    /// A client of version 1 speaks version 1 to a node of version 2, and does not send a request
    /// version 1 does not define: it fails here, with nothing on the link.
    func testOlderVersion1AndTheRequestItMustNotSend() throws {
        let older = v["older"]!.array.first { $0["version"]!.int == 1 }!
        let frames = older["frames"]!.array
        let link = Link(Connection(version: 1, now: { 0 }, wallTime: nil))
        _ = link.replay(Array(frames.dropLast(2)))
        XCTAssertEqual(frames[frames.count - 2]["type"]!.string, "MAKE_GROUP")

        var result: Result<Body, RequestFailure>?
        link.connection.submit(.makeGroup(name: "Hut")) { result = $0 }
        XCTAssertEqual(result, .failure(.unsupported))
        XCTAssertEqual(link.out, [])
        XCTAssertEqual(link.connection.records.items.count, 3)
    }

    /// A client of version 2 reads the node's `SYNCED` as version 2's, without the count.
    func testOlderVersion2() throws {
        let older = v["older"]!.array.first { $0["version"]!.int == 2 }!
        let link = Link(Connection(version: 2, now: { 0 }, wallTime: nil))
        _ = link.replay(older["frames"]!.array)
        XCTAssertEqual(link.connection.agreed, 2)
        XCTAssertEqual(link.events.filter { $0 == .synced }.count, 1)
        XCTAssertEqual(link.connection.records.syncedVersion, 2)
    }

    /// A client of the latest version talking to a node of version 1 does the same.
    func testANodeOfAnEarlierVersionIsNotAskedWhatItCannotDo() throws {
        let node = Node()
        node.version = 1
        node.connection.open()
        node.answerAll()
        XCTAssertEqual(node.connection.agreed, 1)
        var result: Result<Body, RequestFailure>?
        node.connection.submit(.join(id: 3)) { result = $0 }
        XCTAssertEqual(result, .failure(.unsupported))
        node.connection.submit(.endSession(address: Node.bob)) { result = $0 }
        node.answerAll()
        XCTAssertEqual(result, .success(.ok))
    }

    // MARK: One request at a time

    func testOneRequestAtATime() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        var answered = 0
        for _ in 0..<3 { node.connection.submit(.ping) { _ in answered += 1 } }
        XCTAssertEqual(node.sent.count, 1)
        node.answerOne()
        XCTAssertEqual(node.sent.count, 1)
        node.answerAll()
        XCTAssertEqual(answered, 3)
    }

    func testAnAnswerWithAnotherSeqIsIgnored() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        var result: Result<Body, RequestFailure>?
        node.connection.submit(.read(through: 4)) { result = $0 }
        let request = try Frame.decode(node.sent.removeFirst())
        node.connection.receive(try Frame(seq: request.seq &- 1, body: .ok).encode())
        XCTAssertNil(result)
        node.connection.receive(try Frame(seq: request.seq, body: .ok).encode())
        XCTAssertEqual(result, .success(.ok))
    }

    // MARK: Timers

    func testNoAnswerWithinTheWaitAndTheNodeIsGone() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        var first: Result<Body, RequestFailure>?
        var second: Result<Body, RequestFailure>?
        node.connection.submit(.ping) { first = $0 }
        node.connection.submit(.ping) { second = $0 }
        node.time += Companion.answerWait - 0.1
        node.connection.tick()
        XCTAssertNil(first)
        node.time += 0.1
        node.connection.tick()
        XCTAssertEqual(first, .failure(.noAnswer))
        XCTAssertEqual(second, .failure(.closed))
        XCTAssertEqual(node.events.last, .gone)
        XCTAssertNil(node.connection.nextDeadline)
    }

    /// An app that opens again from the timed-out request's callback keeps the HELLO it sent.
    func testOpeningAgainFromTheCallbackOfARequestGivenUpOn() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        var gone = false
        node.connection.onEvent = { if $0 == .gone { gone = true } }
        node.connection.submit(.ping) { _ in
            XCTAssertTrue(gone, "the app is told before the request's callback")
            node.connection.open()
        }
        node.connection.submit(.ping)
        _ = node.sent.removeFirst()
        node.time += Companion.answerWait
        node.connection.tick()
        XCTAssertEqual(node.answerAll().map(\.name), ["HELLO", "SET_TIME", "SYNC"])
        XCTAssertEqual(node.connection.agreed, Companion.version)
    }

    /// Opening again fails what was held only once the new HELLO is out, so a callback that opens
    /// again too sends no second one: one request at a time holds.
    func testOpeningAgainFromTheCallbackOfARequestOpeningClosed() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        var result: Result<Body, RequestFailure>?
        node.connection.submit(.ping) {
            result = $0
            node.connection.open()
        }
        _ = node.sent.removeFirst()
        node.connection.open()
        XCTAssertEqual(result, .failure(.closed))
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body.name }, ["HELLO"])
        XCTAssertEqual(node.answerAll().map(\.name), ["HELLO", "SET_TIME", "SYNC"])
    }

    func testEachNewsFrameOfASyncStartsTheWaitAgain() throws {
        let node = Node()
        node.connection.open()
        node.answerOne()  // INFO
        node.answerOne()  // OK to SET_TIME
        _ = node.sent.removeFirst()  // SYNC, left unanswered
        for _ in 0..<3 {
            node.time += Companion.answerWait - 1
            node.news(.power(Power(millivolts: 3900, percent: 80, flags: 0)))
            node.connection.tick()
        }
        XCTAssertFalse(node.events.contains(.gone))
        node.time += Companion.answerWait
        node.connection.tick()
        XCTAssertEqual(node.events.last, .gone)
    }

    func testAPingWhenNothingWasAskedForIdleSeconds() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        XCTAssertEqual(node.connection.nextDeadline, Companion.idle)
        node.time = Companion.idle - 1
        node.news(.power(Power(millivolts: 3900, percent: 80, flags: 0)))  // news is not an answer
        node.connection.tick()
        XCTAssertEqual(node.sent, [])
        node.time = Companion.idle
        node.connection.tick()
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.ping])
    }

    // MARK: Counted news, and syncing again

    func testMissedNewsSyncsFromTheLeastMessageWhoseStateMayHaveChanged() throws {
        let node = Node()
        node.connection.open()
        node.answerOne()
        node.answerOne()
        _ = node.sent.removeFirst()
        node.news(.message(Node.message(id: 5, state: MessageState.delivered)))
        node.news(.message(Node.message(id: 7, state: MessageState.sent)))
        node.news(.groupMessage(Node.groupMessage(id: 6, state: MessageState.sent)))
        node.news(.message(Node.message(id: 9, state: MessageState.received)))
        node.answerSync()
        XCTAssertEqual(node.connection.records.syncedVersion, Companion.version)

        node.newsCount &+= 1  // one lost
        node.news(.state(MessageState(id: 9, state: MessageState.received, reason: 0, wait: 0)))
        // A sent message may have been delivered since; a sent group message stays sent.
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.sync(after: 6)])
    }

    func testWithNothingThatMayChangeItSyncsFromTheGreatest() throws {
        var r = Records()
        r.syncedVersion = 2
        r.items[4] = .message(Node.message(id: 4, state: MessageState.delivered))
        r.items[8] = .groupMessage(Node.groupMessage(id: 8, state: MessageState.sent))
        r.missedSince = 8
        XCTAssertEqual(r.after(version: 2), 8)
        r.missedSince = nil
        XCTAssertEqual(r.after(version: 2), 8)
        // Speaking a later version than at the last sync: everything, once.
        r.syncedVersion = 1
        XCTAssertEqual(r.after(version: 2), 0)
    }

    /// What was lost may be older than what came after it: losing 11 and then hearing of 12 asks
    /// again from 10, not 12.
    func testMissedNewsSyncsFromNoLaterThanWhatWasHeldBeforeTheGap() throws {
        let node = try synced(holding: [Node.message(id: 10, state: MessageState.delivered)])
        node.newsCount &+= 1  // MESSAGE 11, lost
        node.news(.message(Node.message(id: 12, state: MessageState.received)))
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.sync(after: 10)])
    }

    /// What was missed is kept with the records: an app that stops before the sync after a gap
    /// finishes, and starts again from what it saved, still asks again from before the gap.
    func testMissedNewsOutlivesTheConnection() throws {
        let node = try synced(holding: [Node.message(id: 10, state: MessageState.delivered)])
        node.newsCount &+= 1  // MESSAGE 11, lost
        node.news(.message(Node.message(id: 12, state: MessageState.received)))
        let saved = node.connection.records
        XCTAssertEqual(saved.missedSince, 10)

        let next = Node()
        next.records = saved
        next.connection.open()
        next.answerOne()
        next.answerOne()
        XCTAssertEqual(try next.sent.map { try Frame.decode($0).body }, [.sync(after: 10)])
        next.answerOne()
        XCTAssertNil(next.connection.records.missedSince)
    }

    /// Another client's READ may have been the news lost: a received message still unread is
    /// asked for again.
    func testMissedNewsSyncsFromAMessageStillUnread() throws {
        let node = try synced(holding: [
            Node.message(id: 4, state: MessageState.received),
            Node.message(id: 5, state: MessageState.delivered),
        ])
        node.newsCount &+= 1  // MESSAGE 4, read, lost
        node.news(.power(Power(millivolts: 3900, percent: 80, flags: 0)))
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.sync(after: 3)])
    }

    /// News of a type this client knows that it cannot read is a record lost: it syncs again.
    func testNewsItCannotReadIsNewsMissed() throws {
        let node = try synced(holding: [Node.message(id: 4, state: MessageState.delivered)])
        let message = try Frame(seq: node.newsCount, body: .message(Node.message(id: 5, state: MessageState.received))).encode()
        node.connection.receive(Array(message.prefix(20)))
        node.newsCount &+= 1
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.sync(after: 4)])
    }

    /// A sync that comes to nothing leaves what was missed marked: after ERROR 6 and a new HELLO,
    /// the next sync asks from 10 again, not from the 12 heard of since.
    func testWhatWasMissedStaysMarkedUntilASyncFinishes() throws {
        let node = try synced(holding: [Node.message(id: 10, state: MessageState.delivered)])
        node.newsCount &+= 1  // MESSAGE 11, lost
        node.news(.message(Node.message(id: 12, state: MessageState.delivered)))
        let sync = try Frame.decode(node.sent.removeFirst())
        XCTAssertEqual(sync.body, .sync(after: 10))
        node.connection.receive(try Frame(seq: sync.seq, body: .error(code: ErrorCode.helloFirst)).encode())
        node.answerOne()  // INFO
        node.answerOne()  // OK to SET_TIME
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.sync(after: 10)])
    }

    /// A client away from the node missed every change made meanwhile: a connection's first sync
    /// reaches back to the oldest message whose state may have changed.
    func testAConnectionStartsAsIfNewsWereMissed() throws {
        let node = try synced(holding: [
            Node.message(id: 5, state: MessageState.sent),
            Node.message(id: 8, state: MessageState.delivered),
        ])
        node.connection.close()
        node.connection.open()
        node.answerOne()  // INFO
        node.answerOne()  // OK to SET_TIME
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.sync(after: 4)])
    }

    /// A sync the node refuses is said, and asked for again at the next idle deadline in place of
    /// a PING: not at once, which a node that keeps refusing would answer for ever.
    func testARefusedSyncIsAskedForAgainWhenIdle() throws {
        let node = Node()
        node.connection.open()
        node.answerOne()  // INFO
        node.answerOne()  // OK to SET_TIME
        let sync = try Frame.decode(node.sent.removeFirst())
        node.connection.receive(try Frame(seq: sync.seq, body: .error(code: ErrorCode.notNow)).encode())
        XCTAssertEqual(node.events.last, .syncRefused(code: ErrorCode.notNow))
        XCTAssertEqual(node.sent, [])
        node.time = Companion.idle
        node.connection.tick()
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body.name }, ["SYNC"])
        node.answerAll()
        XCTAssertEqual(node.events.last, .synced)
        node.time = 2 * Companion.idle
        node.connection.tick()
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body.name }, ["PING"])
    }

    /// News missed while a sync is out, and then that sync refused: the sync it wanted waits for
    /// the idle deadline with the one refused, rather than going out at once.
    func testASyncWantedWhileTheRefusedOneWasOutWaitsToo() throws {
        let node = Node()
        node.connection.open()
        node.answerOne()  // INFO
        node.answerOne()  // OK to SET_TIME
        let sync = try Frame.decode(node.sent.removeFirst())
        node.newsCount &+= 1  // one lost
        node.news(.power(Power(millivolts: 3900, percent: 80, flags: 0)))
        node.connection.receive(try Frame(seq: sync.seq, body: .error(code: ErrorCode.notNow)).encode())
        XCTAssertEqual(node.sent, [])
        node.time = Companion.idle
        node.connection.tick()
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body.name }, ["SYNC"])
    }

    /// A sync that finishes some other way pays what a refused one owed: the idle deadline pings.
    func testASyncThatFinishesClearsTheOneOwed() throws {
        let node = Node()
        node.connection.open()
        node.answerOne()  // INFO
        node.answerOne()  // OK to SET_TIME
        let sync = try Frame.decode(node.sent.removeFirst())
        node.connection.receive(try Frame(seq: sync.seq, body: .error(code: ErrorCode.notNow)).encode())
        node.connection.resync()
        node.answerAll()
        XCTAssertEqual(node.events.last, .synced)
        node.time = Companion.idle
        node.connection.tick()
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body.name }, ["PING"])
    }

    /// A sync that missed some of its news proves nothing about what is gone: the next one does.
    func testASyncThatMissedNewsForgetsNothing() throws {
        let node = Node()
        node.connection.open()
        node.answerOne()
        node.answerOne()
        _ = node.sent.removeFirst()  // SYNC
        node.news(.contact(Contact(address: Node.bob, session: 1, name: "Bob")))
        node.answerSync()
        XCTAssertEqual(node.connection.records.contacts.count, 1)

        node.connection.resync()
        _ = node.sent.removeFirst()
        node.newsCount &+= 1  // CONTACT Bob, lost
        node.news(.power(Power(millivolts: 3900, percent: 80, flags: 0)))
        node.answerSync()
        XCTAssertEqual(node.connection.records.contacts.count, 1, "Bob is not taken for gone")
        XCTAssertEqual(node.events.filter { $0 == .synced }.count, 1)
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body.name }, ["SYNC"], "and it syncs again")
    }

    /// The sync's last news lost, with nothing after it to show a gap: `SYNCED`'s count does, and
    /// the client forgets nothing on that sync's account and syncs again.
    func testASyncWhoseLastNewsWasLostIsToldBySyncedsCount() throws {
        let node = try synced(holding: [Node.message(id: 10, state: MessageState.delivered)])
        node.connection.resync()
        _ = node.sent.removeFirst()  // SYNC
        node.news(.contact(Contact(address: Node.bob, session: 1, name: "Bob")))
        node.answerSync()
        XCTAssertEqual(node.connection.records.contacts.count, 1)

        node.connection.resync()
        _ = node.sent.removeFirst()
        node.newsCount &+= 1  // CONTACT Bob, the sync's last news, lost
        let synceds = node.events.filter { $0 == .synced }.count
        node.answerSync()
        XCTAssertEqual(node.connection.records.contacts.count, 1, "Bob is not taken for gone")
        XCTAssertEqual(node.events.filter { $0 == .synced }.count, synceds)
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body }, [.sync(after: 10)], "and it syncs again")

        _ = node.sent.removeFirst()

        // News after it is not taken for another gap.
        node.news(.power(Power(millivolts: 3900, percent: 80, flags: 0)))
        node.answerSync()
        XCTAssertEqual(node.sent, [])
        XCTAssertEqual(node.events.last, .synced)
    }

    /// A client of the latest version reads a node of version 2's `SYNCED` as the two bytes it is.
    func testANodeOfVersion2SyncsWithoutTheCount() throws {
        let node = Node()
        node.version = 2
        node.connection.open()
        node.answerAll()
        XCTAssertEqual(node.connection.agreed, 2)
        XCTAssertEqual(node.events.last, .synced)
        XCTAssertEqual(node.connection.records.syncedVersion, 2)
    }

    /// Records kept from a version 2 connection, synced with a node that speaks an earlier
    /// version, keep their groups: that sync could not have sent them.
    func testASyncOfAnEarlierVersionKeepsTheGroups() {
        var r = Records()
        r.apply(.group(Group(group: Node.hut, name: "Hut")))
        r.beginSync()
        XCTAssertTrue(r.finishSync(version: 1))
        XCTAssertEqual(Array(r.groups.keys), [Node.hut])
        r.beginSync()
        XCTAssertTrue(r.finishSync(version: 2))
        XCTAssertEqual(r.groups, [:])
    }

    func testNewsOfATypeThisClientDoesNotKnowIsCountedAndIgnored() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        let before = node.connection.records
        node.connection.receive([0xBF, node.newsCount, 1, 2, 3])
        node.newsCount &+= 1
        node.news(.power(Power(millivolts: 3900, percent: 80, flags: 0)))
        XCTAssertEqual(node.sent, [], "no sync: nothing was missed")
        XCTAssertNotEqual(node.connection.records, before)
    }

    func testASyncIsTheWholeListOfContactsGroupsAndNeighboursButNotOfMessages() throws {
        let node = Node()
        node.connection.open()
        node.answerOne()
        node.answerOne()
        _ = node.sent.removeFirst()
        node.news(.contact(Contact(address: Node.bob, session: 1, name: "Bob")))
        node.news(.contact(Contact(address: Node.carol, session: 0, name: "Carol")))
        node.news(.group(Group(group: Node.hut, name: "Hut")))
        node.news(.neighbour(Neighbour(routingId: 7, role: 1, snrQuarterDb: 20, heard: 3)))
        node.news(.message(Node.message(id: 3, state: MessageState.received)))
        node.answerSync()

        node.connection.resync()
        _ = node.sent.removeFirst()
        node.news(.contact(Contact(address: Node.bob, session: 1, name: "Bob")))
        node.answerSync()
        let r = node.connection.records
        XCTAssertEqual(Array(r.contacts.keys), [Node.bob])
        XCTAssertEqual(r.groups, [:])
        XCTAssertEqual(r.neighbours, [:])
        XCTAssertEqual(Array(r.items.keys), [3])
    }

    // MARK: Taken for gone

    func testError6StartsAgainAndAsksOnceMore() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        var result: Result<Body, RequestFailure>?
        node.connection.submit(.saveContact(address: Node.carol, name: "Carol")) { result = $0 }
        let refused = try Frame.decode(node.sent.removeFirst())
        node.connection.receive(try Frame(seq: refused.seq, body: .error(code: ErrorCode.helloFirst)).encode())
        XCTAssertNil(result)
        let again = node.answerAll()
        XCTAssertEqual(again.map(\.name), ["HELLO", "SET_TIME", "SYNC", "SAVE_CONTACT"])
        XCTAssertEqual(result, .success(.ok))
    }

    func testAHelloRefusedForTheMTU() throws {
        let node = Node()
        node.connection.open()
        let hello = try Frame.decode(node.sent.removeFirst())
        node.connection.receive(try Frame(seq: hello.seq, body: .error(code: ErrorCode.mtu)).encode())
        XCTAssertEqual(node.events, [.refused(code: ErrorCode.mtu)])
        var result: Result<Body, RequestFailure>?
        node.connection.submit(.ping) { result = $0 }
        XCTAssertEqual(result, .failure(.closed))
    }

    /// A refused HELLO is said before the requests waiting on it fail: one that opens again keeps
    /// the connection it opens.
    func testARefusedHelloIsSaidBeforeTheRequestsWaitingOnIt() throws {
        let node = Node()
        var refused = false
        node.connection.onEvent = { if case .refused = $0 { refused = true } }
        node.connection.open()
        node.connection.submit(.ping) { _ in
            XCTAssertTrue(refused, "the app is told before the request's callback")
            node.connection.open()
        }
        let hello = try Frame.decode(node.sent.removeFirst())
        node.connection.receive(try Frame(seq: hello.seq, body: .error(code: ErrorCode.mtu)).encode())
        XCTAssertEqual(try node.sent.map { try Frame.decode($0).body.name }, ["HELLO"])
    }

    func testSendingAgainWithTheSameRef() throws {
        let node = Node()
        node.connection.open()
        node.answerAll()
        let ref = node.connection.sendMessage("On my way", to: Node.bob)
        node.connection.sendMessage("On my way", to: Node.bob, ref: ref)
        let sent = node.answerAll()
        guard case let .send(a, _, _) = sent[0], case let .send(b, _, _) = sent[1] else { return XCTFail() }
        XCTAssertEqual(a, b)
        var result: Result<Body, RequestFailure>?
        node.connection.sendMessage(String(repeating: "x", count: 129), to: Node.bob) { result = $0 }
        XCTAssertEqual(result, .failure(.invalid(.tooLong(field: "text", limit: 128))))
        XCTAssertEqual(node.sent, [])
    }
}

extension ConnectionTests {
    /// A node and a connection to it that has synced, the node holding `messages`.
    fileprivate func synced(holding messages: [Message]) throws -> Node {
        let node = Node()
        node.connection.open()
        node.answerOne()
        node.answerOne()
        _ = node.sent.removeFirst()
        for m in messages { node.news(.message(m)) }
        node.answerSync()
        XCTAssertEqual(node.sent, [])
        return node
    }
}

/// A connection with its frames caught, and a replay of the specification's.
private final class Link {
    let connection: Connection
    var out: [[UInt8]] = []
    var events: [ConnectionEvent] = []

    init(_ connection: Connection) {
        self.connection = connection
        connection.send = { [unowned self] in out.append($0) }
        connection.onEvent = { [unowned self] in events.append($0) }
    }

    /// Plays the node's half of `frames`, having asked for the client's requests up front, and
    /// checks the client sends its half in order and never two requests at once. Returns each
    /// request's answer.
    func replay(_ frames: [JSON], file: StaticString = #filePath, line: UInt = #line) -> [Result<Body, RequestFailure>] {
        var answers: [Result<Body, RequestFailure>] = []
        connection.open()
        for f in frames where f["from"]!.string == "client" {
            let body = try! Frame.decode(f["frame"]!.bytes).body
            switch body {
            case .hello, .sync, .setTime: continue
            default: connection.submit(body) { answers.append($0) }
            }
        }
        for f in frames {
            XCTAssertLessThanOrEqual(out.count, 1, "two requests at once", file: file, line: line)
            if f["from"]!.string == "client" {
                XCTAssertEqual(out.first.map(Hex.encode), f["frame"]!.string, f["type"]!.string, file: file, line: line)
                if !out.isEmpty { out.removeFirst() }
            } else {
                connection.receive(f["frame"]!.bytes)
            }
        }
        XCTAssertEqual(out, [], file: file, line: line)
        return answers
    }
}

/// A node played by hand: it answers each request as a node with nothing to report would, and
/// sends news when told to.
private final class Node {
    static let bob = Address([UInt8](repeating: 0xB0, count: 32))!
    static let carol = Address([UInt8](repeating: 0xCA, count: 32))!
    static let hut = GroupID([UInt8](repeating: 0x48, count: 8))!

    var time = 0.0
    var version: UInt8 = Companion.version
    var board = "heltec-v3"
    var release = "0.2.0"
    var newsCount: UInt8 = 0
    var sent: [[UInt8]] = []
    var events: [ConnectionEvent] = []
    /// The seq of the last request.
    var seq: UInt8 = 0
    /// What the client starts with.
    var records = Records()
    lazy var connection: Connection = {
        let c = Connection(records: records, now: { [unowned self] in time }, wallTime: { 1_790_000_000 })
        c.send = { [unowned self] in sent.append($0); seq = $0[1] }
        c.onEvent = { [unowned self] in events.append($0) }
        return c
    }()

    func news(_ body: Body) {
        connection.receive(try! Frame(seq: newsCount, body: body).encode())
        newsCount &+= 1
    }

    /// `SYNCED` as this node answers it: with its count from version 3.
    var syncedAnswer: Body { .synced(news: min(version, connection.version) >= 3 ? newsCount : nil) }

    /// Answers the last request, a `SYNC`, now.
    func answerSync() {
        connection.receive(try! Frame(seq: seq, body: syncedAnswer).encode())
    }

    /// Answers the oldest request sent.
    @discardableResult
    func answerOne() -> Body {
        let request = try! Frame.decode(sent.removeFirst())
        let answer: Body
        switch request.body {
        case .hello:
            newsCount = 0
            let v4 = min(version, connection.version) >= 4
            answer = .info(version: version, firmware: "test", board: v4 ? board : nil, release: v4 ? release : nil)
        case .sync: answer = syncedAnswer
        case .send, .sendGroup, .sendInvite: answer = .queued(id: 1)
        case .makeGroup: answer = .made(group: Node.hut)
        default: answer = .ok
        }
        connection.receive(try! Frame(seq: request.seq, body: answer).encode())
        return request.body
    }

    /// Answers until nothing is waiting; returns what was asked.
    @discardableResult
    func answerAll() -> [Body] {
        var asked: [Body] = []
        while !sent.isEmpty { asked.append(answerOne()) }
        return asked
    }

    static func message(id: UInt32, state: UInt8) -> Message {
        Message(id: id, contact: bob, time: 0, flags: 0, state: state, reason: 0, wait: 0, text: "x")
    }

    static func groupMessage(id: UInt32, state: UInt8) -> GroupMessage {
        GroupMessage(id: id, group: hut, from: 0, time: 0, flags: 0, state: state, reason: 0, wait: 0, text: "x")
    }
}
