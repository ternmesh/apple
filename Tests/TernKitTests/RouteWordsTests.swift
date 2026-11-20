// How a message went, what a trace found, and the range test's log, in the app's words (version
// 18): the same words as the Android app's.

import XCTest

@testable import TernKit

final class RouteWordsTests: XCTestCase {
    // The vectors' first two addresses: RFC 8032's first two Ed25519 public keys.
    private let ada = Address(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")!
    private let bob = Address(hex: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")!
    private let hut = GroupID([UInt8](repeating: 0x48, count: 8))!
    private let relay: UInt32 = 0x1D2E_3F40

    private lazy var records: Records = {
        var r = Records()
        r.apply(.nodeSelf(NodeSelf(address: ada, role: 0, region: "EU868", power: 14, time: 0)))
        r.apply(.contact(Contact(address: bob, session: 1, name: "Bob")))
        r.syncedVersion = 18
        return r
    }()
    private lazy var names = RouteNames(records, given: [relay: "Hilltop"])
    private lazy var bobs = records.routingId(of: bob)

    private func received() -> Item {
        .message(Message(id: 18, contact: bob, time: 0, flags: 0, state: MessageState.received, reason: 0, wait: 0, text: "See you"))
    }

    private func sent(_ state: UInt8) -> Item {
        .message(Message(id: 17, contact: bob, time: 0, flags: 0, state: state, reason: 0, wait: 0, text: "Leaving now"))
    }

    private func route(_ id: UInt32, _ hops: UInt8, _ snr: Int8, _ rssi: Int16, _ via: UInt32, _ goes: UInt8, _ took: UInt32) -> Route {
        Route(id: id, hops: hops, snr: snr, rssi: rssi, via: via, goes: goes, took: took)
    }

    private func line(_ item: Item, _ r: Route?, _ n: RouteNames? = nil) -> String? {
        RouteWords.line(item, r, records: records, names: n ?? names)
    }

    func testReceivedDirectOrRelayed() {
        XCTAssertEqual(line(received(), route(18, 1, 26, -71, 0, 0, 0)), "Direct · SNR 6.5 dB")
        XCTAssertEqual(line(received(), route(18, 2, 19, -101, 0, 0, 0)), "2 hops · SNR 4.8 dB")
        XCTAssertEqual(line(received(), route(18, 3, -38, -112, 0, 0, 0)), "3 hops · SNR -9.5 dB")
        XCTAssertNil(line(received(), route(18, 0, 0, 0, 0, 0, 0)), "nothing known")
        XCTAssertNil(line(received(), nil), "no ROUTE: a node of version 17, or one that kept none")
    }

    func testAGroupMessageCameAtMostThatFar() {
        let group = GroupMessage(
            id: 19, group: hut, from: bobs, time: 0, flags: 0, state: MessageState.received, reason: 0, wait: 0, text: "Hut's empty")
        XCTAssertEqual(line(.groupMessage(group), route(19, 2, 19, -101, 0, 0, 0)), "≤2 hops · SNR 4.8 dB")
        XCTAssertEqual(line(.groupMessage(group), route(19, 1, -9, -117, 0, 0, 0)), "Direct · SNR -2.3 dB")
        let (facts, notes) = RouteWords.facts(.groupMessage(group), route(19, 2, 19, -101, 0, 0, 0), records: records, names: names)
        XCTAssertEqual(facts.first?.value, "At most 2 hops: 2 or 1")
        XCTAssertTrue(notes.first!.hasPrefix("A group message's writer hides how far off it is"))
        var mine = group
        mine.from = 0
        mine.state = MessageState.sent
        XCTAssertEqual(line(.groupMessage(mine), route(19, 0, 0, 0, 0, 2, 0)), "Went out 2 times")
    }

    func testSentViaARelayOrDirect() {
        XCTAssertEqual(
            line(sent(MessageState.delivered), route(17, 2, 22, -98, relay, 2, 19_640)),
            "Delivered via Hilltop · reply 2 hops · 19.6 s")
        XCTAssertEqual(
            line(sent(MessageState.delivered), route(17, 2, 22, -98, relay, 1, 3_120), RouteNames(records)),
            "Delivered via 1d2e3f40 · reply 2 hops · 3.1 s")
        XCTAssertEqual(line(sent(MessageState.delivered), route(17, 1, 30, -60, bobs, 1, 1_200)), "Delivered direct · 1.2 s")
        XCTAssertEqual(
            line(sent(MessageState.delivered), route(17, 2, 30, -60, bobs, 1, 1_200)), "Delivered direct · reply 2 hops · 1.2 s")
        // Out through a relay, and the acknowledgement straight back: the hop is the reply's.
        XCTAssertEqual(
            line(sent(MessageState.delivered), route(17, 1, 30, -60, relay, 1, 300)), "Delivered via Hilltop · reply direct · 0.3 s")
        XCTAssertEqual(line(sent(MessageState.sent), route(17, 0, 0, 0, relay, 1, 0)), "Sent via Hilltop")
        XCTAssertEqual(line(sent(MessageState.sent), route(17, 0, 0, 0, relay, 2, 0)), "Sent via Hilltop · try 2")
        XCTAssertEqual(line(sent(MessageState.waiting), route(17, 0, 0, 0, bobs, 1, 0)), "Sent direct")
        XCTAssertEqual(line(sent(MessageState.notDelivered), route(17, 0, 0, 0, relay, 4, 0)), "Last tried via Hilltop · 4 tries")
        XCTAssertNil(line(sent(MessageState.waiting), route(17, 0, 0, 0, 0, 0, 0)), "gone nowhere yet")
    }

    func testTheDetailsSayEveryField() {
        let (facts, notes) = RouteWords.facts(
            sent(MessageState.delivered), route(17, 2, 22, -98, relay, 2, 19_640), records: records, names: names)
        XCTAssertEqual(facts.map(\.label), [
            "First went to", "Tries on the air", "Acknowledgement came back", "Signal-to-noise of the last hop",
            "Signal strength of the last hop", "Round trip",
        ])
        XCTAssertEqual(facts.map(\.value), ["Hilltop (1d2e3f40)", "2", "2 hops", "5.5 dB", "-98 dBm", "19.6 s"])
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].hasPrefix("The hops and signal are the acknowledgement's"))
        let (came, why) = RouteWords.facts(received(), route(18, 3, -38, -112, 0, 0, 0), records: records, names: names)
        XCTAssertEqual(came.first?.value, "3 hops: 2 relays passed it on")
        XCTAssertTrue(why.last!.hasPrefix("No message names the relays"))
        XCTAssertEqual(
            RouteWords.facts(sent(MessageState.sent), route(17, 0, 0, 0, bobs, 1, 0), records: records, names: names).facts.first?.value,
            "Straight to Bob")
        XCTAssertTrue(RouteWords.facts(received(), nil, records: records, names: names).notes[0].hasPrefix("Your node hasn't said"))
    }

    func testNamesYourNodeContactsRelaysAndIds() {
        XCTAssertEqual(names.name(records.routingId(of: ada)), "your node")
        XCTAssertEqual(names.name(bobs), "Bob")
        XCTAssertEqual(names.name(relay), "Hilltop")
        XCTAssertEqual(names.label(0x3031_3233), "30313233", "one word, as the trace shows it")
        XCTAssertFalse(names.isNameable(bobs))
        XCTAssertFalse(names.isNameable(records.routingId(of: ada)))
        XCTAssertTrue(names.isNameable(relay))
    }

    func testATraceInWords() {
        let bobBytes = [UInt8(bobs >> 24), UInt8(bobs >> 16 & 0xFF), UInt8(bobs >> 8 & 0xFF), UInt8(bobs & 0xFF)]
        let entries: [UInt8] = [0x1D, 0x2E, 0x3F, 0x40, 24] + bobBytes + [40] + [0x1D, 0x2E, 0x3F, 0x40, 30]
        let answered = Traced(id: 20, to: bobs, result: Traced.answered, out: 2, took: 3_120, snr: 26, entries: entries)
        XCTAssertEqual(RouteWords.result(answered, target: "Bob", records: records, names: names), "Answered by Bob")
        XCTAssertEqual(RouteWords.summary(answered), "2 hops out · 2 hops back · 3.1 s")
        let one: [UInt8] = [0x1D, 0x2E, 0x3F, 0x40, 24]
        let keeper = Traced(id: 20, to: bobs, result: Traced.keeper, out: 1, took: 900, snr: 26, entries: one)
        XCTAssertEqual(
            RouteWords.result(keeper, target: "Bob", records: records, names: names),
            "Answered by Hilltop, which keeps Bob's messages while it sleeps: that's as far as they go until it wakes")
        let stuck = Traced(id: 20, to: bobs, result: Traced.noRoute, out: 1, took: 900, snr: 26, entries: one)
        XCTAssertEqual(
            RouteWords.result(stuck, target: "Bob", records: records, names: names), "Got as far as Hilltop, which has no route to Bob")
        let none = Traced(id: 21, to: relay, result: Traced.notAnswered, out: 0, took: 0, snr: 0, entries: [])
        XCTAssertEqual(
            RouteWords.result(none, target: "Hilltop", records: records, names: names),
            "No answer in time. Hilltop may be out of reach, or a relay on the way may not pass traces on.")
        let never = Traced(id: 22, to: 0x3031_3233, result: Traced.notBegun, out: 0, took: 0, snr: 0, entries: [])
        XCTAssertEqual(
            RouteWords.result(never, target: "30313233", records: records, names: names), "Not begun: your node has no route to 30313233")
    }

    /// A leaf answers a trace only from a node it shares a session with: a trace to one that goes
    /// unanswered says so.
    func testALeafWithNoSessionDropsTraces() {
        let leaf: UInt32 = 0x0A0B_0C0D
        var r = Records()
        r.apply(.nodeSelf(NodeSelf(address: ada, role: 1, region: "EU868", power: 14, time: 0)))
        r.apply(.contact(Contact(address: bob, session: 0, name: "Bob")))
        r.apply(.neighbour(Neighbour(routingId: leaf, role: 0, snrQuarterDb: 20, heard: 5)))
        r.apply(.neighbour(Neighbour(routingId: relay, role: 1, snrQuarterDb: 20, heard: 5)))
        r.syncedVersion = 18
        let bobs = r.routingId(of: bob)
        r.apply(.neighbour(Neighbour(routingId: bobs, role: 0, snrQuarterDb: 24, heard: 3)))
        XCTAssertTrue(r.isLeafWithoutSession(leaf), "a leaf neighbour, no contact")
        XCTAssertTrue(r.isLeafWithoutSession(bobs), "a leaf contact, but no session")
        XCTAssertFalse(r.isLeafWithoutSession(relay), "a relay answers anyone")
        XCTAssertFalse(r.isLeafWithoutSession(0x3031_3233), "not a neighbour: not known to be a leaf")
        r.apply(.contact(Contact(address: bob, session: 1, name: "Bob")))
        XCTAssertFalse(r.isLeafWithoutSession(bobs), "a session: it answers")

        let none = Traced(id: 21, to: leaf, result: Traced.notAnswered, out: 0, took: 0, snr: 0, entries: [])
        XCTAssertEqual(
            RouteWords.result(none, target: "0a0b0c0d", records: r, names: RouteNames(r)),
            "No answer from 0a0b0c0d. Handhelds (leaves) answer traces only from nodes they have a secure session with.")
        let far = Traced(id: 22, to: relay, result: Traced.notAnswered, out: 0, took: 0, snr: 0, entries: [])
        XCTAssertTrue(RouteWords.result(far, target: "Hilltop", records: r, names: RouteNames(r)).hasPrefix("No answer in time."))
    }

    func testWhereATraceIs() {
        XCTAssertEqual(RouteWords.step(TraceRun(to: bobs)), "Handing it to your node…")
        XCTAssertEqual(RouteWords.step(TraceRun(to: bobs, id: 20, state: MessageState.waiting, reason: 1)), "Finding a route…")
        XCTAssertEqual(
            RouteWords.step(TraceRun(to: bobs, id: 20, state: MessageState.waiting, reason: 4, wait: 12)),
            "Waiting for the airtime budget · about 12 s")
        XCTAssertEqual(RouteWords.step(TraceRun(to: bobs, id: 20, state: MessageState.sent)), "Out: waiting for the answer…")
        XCTAssertEqual(RouteWords.step(TraceRun(to: bobs, id: 20)), "Waiting to go…")
    }

    func testARangePingInWords() {
        let ping = RangePing(n: 3, at: 0, text: "range #3", fix: nil, after: 16, id: 17)
        XCTAssertEqual(
            RouteWords.rangeRow(RangeRow(ping: ping, state: MessageState.delivered, route: route(17, 2, 22, -98, relay, 2, 19_640)), names: names),
            "Delivered · 2 hops · SNR 5.5 dB · -98 dBm · 19.6 s · via Hilltop")
        XCTAssertEqual(
            RouteWords.rangeRow(RangeRow(ping: ping, state: MessageState.sent, route: route(17, 0, 0, 0, relay, 1, 0)), names: names),
            "Sent · via Hilltop")
        XCTAssertEqual(RouteWords.rangeRow(RangeRow(ping: ping, state: MessageState.delivered, route: nil), names: names), "Delivered")
        var away = ping
        away.id = nil
        away.unsent = .notConnected
        XCTAssertEqual(RouteWords.rangeRow(RangeRow(ping: away, state: nil, route: nil), names: names), "Not sent: node not connected")
    }

    func testNumbersAsTheyAreShown() {
        XCTAssertEqual(RouteWords.snr(0), "0.0 dB")
        XCTAssertEqual(RouteWords.snr(-1), "-0.3 dB")
        XCTAssertEqual(RouteWords.snr(127), "31.8 dB")
        XCTAssertEqual(RouteWords.snr(-128), "-32.0 dB")
        XCTAssertEqual(RouteWords.took(0), "0.0 s")
        XCTAssertEqual(RouteWords.took(49), "0.0 s")
        XCTAssertEqual(RouteWords.took(50), "0.1 s")
        XCTAssertEqual(RouteWords.took(.max), "4294967.3 s")
    }
}

final class RangeTestTests: XCTestCase {
    private let bob = Address([UInt8](repeating: 0xB0, count: 32))!
    private let carol = Address([UInt8](repeating: 0xCA, count: 32))!
    private let start = 1_790_000_000.0

    private func sent(_ id: UInt32, _ text: String, _ state: UInt8, to: Address? = nil) -> Body {
        .message(Message(id: id, contact: to ?? bob, time: 0, flags: 0, state: state, reason: 0, wait: 0, text: text))
    }

    func testPingsAreNumberedAndDueEachInterval() {
        var t = RangeTest(to: bob, interval: 30, startedAt: start)
        XCTAssertEqual(t.nextAt, start, "the first goes at once")
        let first = t.next(at: start, fix: PhoneFix(lat: 45.5, lon: -66.1, accuracy: 4, age: 1), after: 16)
        XCTAssertEqual(first.text, "range #1")
        XCTAssertEqual(t.nextAt, start + 30)
        let second = t.next(at: start + 30, fix: nil, after: 17, unsent: .notConnected)
        XCTAssertEqual(second.n, 2)
        XCTAssertEqual(t.pings[1].unsent, .notConnected)
        XCTAssertEqual(t.nextAt, start + 60)
        XCTAssertFalse(RangeTest.intervals.contains(29))
        XCTAssertFalse(RangeTest.intervals.contains(61))
        XCTAssertEqual(RangeTest.defaultInterval, 30)
    }

    func testWhatEachBecameIsReadFromTheRecords() {
        var t = RangeTest(to: bob, interval: 30, startedAt: start)
        _ = t.next(at: start, fix: nil, after: 16)
        t.queued(1, id: 17)
        _ = t.next(at: start + 30, fix: nil, after: 17)
        t.queued(2, id: 18)
        _ = t.next(at: start + 60, fix: nil, after: 18)
        t.unsent(3, .refused)
        var r = Records()
        r.apply(sent(17, "range #1", MessageState.delivered))
        r.apply(.route(Route(id: 17, hops: 2, snr: 22, rssi: -98, via: 0x1D2E_3F40, goes: 2, took: 19_640)))
        r.apply(sent(18, "range #2", MessageState.notDelivered))
        let rows = t.rows(r)
        XCTAssertTrue(rows[0].isDelivered)
        XCTAssertEqual(rows[0].route?.hops, 2)
        XCTAssertEqual(rows[1].state, MessageState.notDelivered)
        XCTAssertNil(rows[2].state)
        let tally = RangeTest.tally(rows)
        XCTAssertEqual(tally.delivered, 1, "one delivered")
        XCTAssertEqual(tally.sent, 2, "of the two that went")
        XCTAssertEqual(rows.map(RangeTest.result), ["delivered", "not_delivered", "refused"])
    }

    func testAPingTheNodeDidNotAnswerForIsFoundByItsText() {
        var t = RangeTest(to: bob, interval: 30, startedAt: start)
        _ = t.next(at: start, fix: nil, after: 20)
        t.unsent(1, .unanswered)
        var r = Records()
        // The same text from an earlier test, to another contact, and one received: none is it.
        r.apply(sent(12, "range #1", MessageState.delivered))
        r.apply(sent(21, "range #1", MessageState.sent, to: carol))
        r.apply(sent(22, "range #1", MessageState.received))
        XCTAssertFalse(t.resolve(r))
        r.apply(sent(23, "range #1", MessageState.sent))
        XCTAssertTrue(t.resolve(r))
        XCTAssertEqual(t.pings[0].id, 23)
        XCTAssertNil(t.pings[0].unsent)
        // An answer that comes after does not undo it.
        t.unsent(1, .unanswered)
        XCTAssertEqual(t.pings[0].id, 23)
    }

    func testTheCsvHasAHeaderAndALineForEachPing() {
        var t = RangeTest(to: bob, interval: 45, startedAt: start)
        _ = t.next(at: start, fix: PhoneFix(lat: 45.123456789, lon: -66.5, accuracy: 4.4, age: 2), after: 16)
        t.queued(1, id: 17)
        _ = t.next(at: start + 45, fix: nil, after: 17, unsent: .notConnected)
        var r = Records()
        r.apply(sent(17, "range #1", MessageState.delivered))
        r.apply(.route(Route(id: 17, hops: 2, snr: -38, rssi: -112, via: 0x1D2E_3F40, goes: 3, took: 19_640)))
        let csv = t.csv(t.rows(r), time: { $0 == self.start ? "2026-09-21T14:13:20Z" : "2026-09-21T14:14:05Z" }) {
            $0 == 0x1D2E_3F40 ? "Hilltop, north" : nil
        }
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "n,time,lat,lon,accuracy_m,fix_age_s,to,message_id,result,hops,snr_db,rssi_dbm,round_trip_s,tries,via_id,via")
        XCTAssertEqual(
            lines[1],
            "1,2026-09-21T14:13:20Z,45.1234568,-66.5000000,4,2,b0b0b0b0,17,delivered,2,-9.50,-112,19.640,3,1d2e3f40,\"Hilltop, north\"")
        XCTAssertEqual(lines[2], "2,2026-09-21T14:14:05Z,,,,,b0b0b0b0,,not_connected,,,,,,,")
        XCTAssertEqual(RangeTest.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
    }
}
