// The codec against the specification's vectors (vectors/companion.json here, a copy of
// vectors/companion.json in ternmesh/spec): its conformance section, as a client.

import Foundation
import XCTest

@testable import TernKit

final class CompanionVectorTests: XCTestCase {
    static let vectors: [String: JSON] = {
        let url = Bundle.module.url(forResource: "companion", withExtension: "json", subdirectory: "vectors")!
        let data = try! Data(contentsOf: url)
        guard case let .object(o) = try! JSONDecoder().decode(JSON.self, from: data) else { fatalError() }
        return o
    }()

    var v: [String: JSON] { Self.vectors }

    func testCrcCheck() {
        let c = v["crc_check"]!
        XCTAssertEqual(ByteStream.crc16(c["input"]!.bytes), UInt16(c["crc"]!.int))
    }

    func testFramesBuiltReadWrappedAndFound() throws {
        let cases = v["frames"]!.array
        XCTAssertGreaterThanOrEqual(cases.count, 66)
        for c in cases {
            let name = c["type"]!.string
            let frame = Frame(seq: UInt8(c["seq"]!.int), body: try body(name, c["fields"]!.object))
            XCTAssertEqual(Hex.encode(try frame.encode()), c["frame"]!.string, name)
            let read = try Frame.decode(c["frame"]!.bytes)
            XCTAssertEqual(read, frame, name)
            XCTAssertEqual(read.body.name, name)
            XCTAssertEqual(Hex.encode(ByteStream.wrap(c["frame"]!.bytes)), c["stream"]!.string, name)
            var reader = StreamReader()
            XCTAssertEqual(reader.push(c["stream"]!.bytes), [.frame(c["frame"]!.bytes)], name)
        }
    }

    func testExtendedBytesAfterTheFieldsAreIgnored() throws {
        for c in v["extended"]!.array {
            let name = c["type"]!.string
            let expected = Frame(seq: UInt8(c["seq"]!.int), body: try body(name, c["fields"]!.object))
            XCTAssertEqual(try Frame.decode(c["frame"]!.bytes), expected, name)
        }
    }

    func testRejectedAClientDiscardsEachAndANodeAnswersTheCode() {
        for c in v["rejected"]!.array {
            let why = c["why"]!.string
            let bytes = c["frame"]!.bytes
            do {
                _ = try Frame.decode(bytes)
                XCTFail("read: \(why)")
            } catch let error as DecodeError {
                let answer: UInt8? = if case .null = c["answer"]! { nil } else { UInt8(c["answer"]!.int) }
                XCTAssertEqual(Frame.errorCode(for: bytes, error), answer, why)
            } catch {
                XCTFail("\(error): \(why)")
            }
        }
    }

    func testStreamsAllAtOnceAndAByteAtATime() {
        for c in v["streams"]!.array {
            let why = c["why"]!.string
            let expected = c["items"]!.array.map { i -> StreamItem in
                if let f = i["frame"] { return .frame(f.bytes) }
                return .text(i["text"]!.bytes)
            }
            var whole = StreamReader()
            XCTAssertEqual(whole.push(c["stream"]!.bytes), expected, why)
            XCTAssertEqual(Hex.encode(whole.pending), c["pending"]!.string, why)

            // A byte at a time the frames are the same and in the same order, with the text
            // between them in as many pieces as it came in.
            var slow = StreamReader()
            var items: [StreamItem] = []
            for b in c["stream"]!.bytes {
                for i in slow.push([b]) {
                    if case let .text(t) = i, case let .text(last)? = items.last {
                        items[items.count - 1] = .text(last + t)
                    } else {
                        items.append(i)
                    }
                }
            }
            XCTAssertEqual(items, expected, why)
            XCTAssertEqual(Hex.encode(slow.pending), c["pending"]!.string, why)
        }
    }

    func testExchangeEveryFrameReadsAndBuildsBackToTheSameBytes() throws {
        for c in v["exchange"]!.array {
            let name = c["type"]!.string
            let f = try Frame.decode(c["frame"]!.bytes)
            XCTAssertEqual(f.body.name, name)
            XCTAssertEqual(Int(f.seq), c["seq"]!.int, name)
            XCTAssertEqual(c["from"]!.string == "client", f.body.type.isRequestType, name)
            XCTAssertEqual(Hex.encode(try f.encode()), c["frame"]!.string, name)
        }
    }

    /// Each older connection's frames read by the version its client speaks, and build back; one
    /// that version does not define is undefined.
    func testOlderEveryFrameReadsByItsVersion() throws {
        for c in v["older"]!.array {
            let version = UInt8(c["version"]!.int)
            for f in c["frames"]!.array {
                let name = f["type"]!.string
                // The clients of versions 1, 3 and 4 end with a request their version does not
                // define.
                if let latest = try? Frame.decode(f["frame"]!.bytes), latest.body.since > version {
                    XCTAssertThrowsError(try Frame.decode(f["frame"]!.bytes, version: version), name)
                    continue
                }
                let frame = try Frame.decode(f["frame"]!.bytes, version: version)
                XCTAssertEqual(frame.body.name, name)
                XCTAssertEqual(Hex.encode(try frame.encode()), f["frame"]!.string, "\(version) \(name)")
            }
        }
        // And by the latest version, version 2's SYNCED is cut short, and version 3's INFO.
        XCTAssertThrowsError(try Frame.decode([0x43, 0x02]))
        XCTAssertEqual(try Frame.decode([0x43, 0x02], version: 2).body, .synced(news: nil))
        let info3 = Hex.decode("420104147465726e20302e322e302068656c7465632d7633")!
        XCTAssertThrowsError(try Frame.decode(info3))
        // A node of version 3's INFO, read by a client of the latest version, is the version 3 it says.
        XCTAssertEqual(
            try Frame.decode(Hex.decode("420103047465726e")!).body,
            .info(version: 3, firmware: "tern", board: nil, release: nil))
        XCTAssertEqual(
            try Frame.decode(info3, version: 3).body,
            .info(version: 4, firmware: "tern 0.2.0 heltec-v3", board: nil, release: nil))
    }

    /// Speaking `version`, a frame of a type only a later version defines is of a type this one
    /// does not: a node answers a request `ERROR` with the code given, and a client ignores news
    /// and discards an answer, whose code is null.
    func testUnknownToOlder() throws {
        let cases = v["unknown_to_older"]!.array
        XCTAssertGreaterThanOrEqual(cases.count, 11)
        for c in cases {
            let name = c["type"]!.string
            let version = UInt8(c["version"]!.int)
            let bytes = c["frame"]!.bytes
            // The latest version reads it, as what it is.
            XCTAssertEqual(try Frame.decode(bytes).body.name, name)
            XCTAssertGreaterThan(Companion.since(type: bytes[0]), version, name)
            XCTAssertThrowsError(try Frame.decode(bytes, version: version), name) { error in
                XCTAssertEqual(error as? DecodeError, .undefined, name)
                let answer: UInt8? = if case .null = c["answer"]! { nil } else { UInt8(c["answer"]!.int) }
                XCTAssertEqual(Frame.errorCode(for: bytes, .undefined), answer, name)
            }
            XCTAssertEqual(c["why"]!.string, "a type this version does not define", name)

            // A connection speaking that version, to a node of the latest, ignores the news but
            // counts it, and discards the answer even with the seq of its request: its sync
            // finishes, with nothing missed.
            let c = Connection(version: version, now: { 0 }, wallTime: nil)
            var events: [ConnectionEvent] = []
            var sent: [[UInt8]] = []
            c.send = { sent.append($0) }
            c.onEvent = { events.append($0) }
            c.open()
            let info = Body.info(version: Companion.version, firmware: "t", board: "b", release: "1")
            c.receive(try Frame(seq: sent.removeFirst()[1], body: info).encode())
            let sync = try Frame.decode(sent.removeFirst())
            guard case .sync = sync.body else { return XCTFail(name) }
            for n: UInt8 in 0..<5 { c.receive([0xBF, n]) }
            events.removeAll()
            var frame = bytes
            if frame[0].isAnswerType { frame[1] = sync.seq }
            c.receive(frame)
            XCTAssertEqual(events, [], name)
            XCTAssertEqual(c.records.me, nil, name)
            let count: UInt8 = frame[0].isNewsType ? 6 : 5
            c.receive(try Frame(seq: sync.seq, body: .synced(news: version >= 3 ? count : nil)).encode())
            XCTAssertEqual(events, [.synced], name)
            XCTAssertNil(c.records.missedSince, name)
            XCTAssertEqual(sent, [], name)
        }
    }

    /// A frame of a later version than the one both ends speak is one that version does not
    /// define.
    func testAFrameOfALaterVersionIsUndefined() throws {
        let gone = try Frame(seq: 1, body: .groupGone(group: GroupID([UInt8](repeating: 1, count: 8))!)).encode()
        XCTAssertThrowsError(try Frame.decode(gone, version: 1)) { XCTAssertEqual($0 as? DecodeError, .undefined) }
        XCTAssertNoThrow(try Frame.decode(gone, version: 2))
        let end = try Frame(seq: 1, body: .endSession(address: Address([UInt8](repeating: 1, count: 32))!)).encode()
        XCTAssertThrowsError(try Frame.decode(end, version: 0)) { XCTAssertEqual($0 as? DecodeError, .undefined) }
        XCTAssertNoThrow(try Frame.decode(end, version: 1))
        // Undefined before its fields are read: cut short, it is still a type the version lacks.
        XCTAssertThrowsError(try Frame.decode([0x1A, 1], version: 0)) { XCTAssertEqual($0 as? DecodeError, .undefined) }
        XCTAssertThrowsError(try Frame.decode([0x1A, 1], version: 1)) { XCTAssertEqual($0 as? DecodeError, .malformed) }
        XCTAssertThrowsError(try Frame.decode([0x8A, 1], version: 1)) { XCTAssertEqual($0 as? DecodeError, .undefined) }
        XCTAssertThrowsError(try Frame.decode([0x32, 1], version: 3)) { XCTAssertEqual($0 as? DecodeError, .undefined) }
        XCTAssertThrowsError(try Frame.decode([0x46, 1, 0, 0, 0, 0], version: 3)) { XCTAssertEqual($0 as? DecodeError, .undefined) }
        XCTAssertNoThrow(try Frame.decode([0x32, 1], version: 4))
        for type: UInt8 in [0x33, 0x34, 0x35, 0x8E, 0x8F, 0x90, 0x91] {
            XCTAssertEqual(Companion.since(type: type), 5)
            XCTAssertThrowsError(try Frame.decode([type, 1], version: 4)) { XCTAssertEqual($0 as? DecodeError, .undefined) }
            XCTAssertThrowsError(try Frame.decode([type, 1], version: 5)) { XCTAssertEqual($0 as? DecodeError, .malformed) }
        }
    }

    func testAFrameThatNeverFinishesIsGivenUpAsText() {
        var r = StreamReader()
        XCTAssertEqual(r.push(Hex.decode("f554000240")!), [])
        XCTAssertEqual(r.stale(), [.text(Hex.decode("f554000240")!)])
        XCTAssertEqual(r.pending, [])
        // And a frame after it is still found.
        XCTAssertEqual(r.push(Hex.decode("f55400024004a7e8")!), [.frame([0x40, 0x04])])
    }

    func testEncodeRefusesWhatIsNotAFrame() {
        let bob = Address(hex: String(repeating: "00", count: 32))!
        XCTAssertNil(Address(hex: "00"))
        XCTAssertThrowsError(try Frame(seq: 1, body: .send(ref: 1, to: bob, text: String(repeating: "x", count: 129))).encode())
        XCTAssertThrowsError(try Frame(seq: 1, body: .saveContact(address: bob, name: String(repeating: "é", count: 16))).encode())
        XCTAssertNoThrow(try Frame(seq: 1, body: .send(ref: 1, to: bob, text: String(repeating: "x", count: 128))).encode())
        let chunk = [UInt8](repeating: 7, count: Companion.updateChunk)
        XCTAssertLessThanOrEqual(try Frame(seq: 1, body: .updateData(offset: 0, data: chunk)).encode().count, Companion.maxFrame)
        XCTAssertThrowsError(try Frame(seq: 1, body: .updateData(offset: 0, data: chunk + [7])).encode())
    }

    // MARK: The vectors' fields, by name, as the codec's types.

    private func body(_ name: String, _ f: [String: JSON]) throws -> Body {
        func u8(_ k: String) -> UInt8 { UInt8(f[k]!.int) }
        func i8(_ k: String) -> Int8 { Int8(f[k]!.int) }
        func u16(_ k: String) -> UInt16 { UInt16(f[k]!.int) }
        func i16(_ k: String) -> Int16 { Int16(f[k]!.int) }
        func u32(_ k: String) -> UInt32 { UInt32(f[k]!.int) }
        func i32(_ k: String) -> Int32 { Int32(f[k]!.int) }
        func str(_ k: String) -> String { f[k]!.string }
        func addr(_ k: String) -> Address { Address(f[k]!.bytes)! }
        func gid(_ k: String) -> GroupID { GroupID(f[k]!.bytes)! }
        func sharing() -> PositionSharing {
            PositionSharing(precision: u8("precision"), fields: u8("fields"), interval: u16("interval"), minutes: u16("minutes"))
        }
        func position() -> Position {
            Position(
                precision: u8("precision"), lat: i32("lat"), lon: i32("lon"), altitude: i16("altitude"),
                accuracy: u8("accuracy"), age: u32("age"))
        }
        switch name {
        case "HELLO": return .hello(version: u8("version"))
        case "SYNC": return .sync(after: u32("after"))
        case "PING": return .ping
        case "SET_TIME": return .setTime(u32("time"))
        case "SET":
            switch u8("setting") {
            case 1: return .set(.region(str("value")))
            case 2: return .set(.role(u8("value")))
            case 3: return .set(.power(i8("value")))
            case 4: return .set(.passkey(u32("value")))
            default: throw DecodeError.undefined
            }
        case "SEND": return .send(ref: u32("ref"), to: addr("to"), text: str("text"))
        case "READ": return .read(through: u32("through"))
        case "SAVE_CONTACT": return .saveContact(address: addr("address"), name: str("name"))
        case "REMOVE_CONTACT": return .removeContact(address: addr("address"))
        case "END_SESSION": return .endSession(address: addr("address"))
        case "MAKE_GROUP": return .makeGroup(name: str("name"))
        case "LEAVE_GROUP": return .leaveGroup(group: gid("group"))
        case "NAME_GROUP": return .nameGroup(group: gid("group"), name: str("name"))
        case "SEND_GROUP": return .sendGroup(ref: u32("ref"), group: gid("group"), text: str("text"))
        case "SEND_INVITE": return .sendInvite(group: gid("group"), to: addr("to"))
        case "JOIN": return .join(id: u32("id"))
        case "OK": return .ok
        case "ERROR": return .error(code: u8("code"))
        case "INFO":
            return .info(version: u8("version"), firmware: str("firmware"), board: f["board"]?.string, release: f["release"]?.string)
        case "SYNCED": return .synced(news: f["news"].map { UInt8($0.int) })
        case "QUEUED": return .queued(id: u32("id"))
        case "MADE": return .made(group: gid("group"))
        case "UPDATE_BEGIN": return .updateBegin(size: u32("size"), digest: Digest(f["digest"]!.bytes)!)
        case "UPDATE_DATA": return .updateData(offset: u32("offset"), data: f["data"]!.bytes)
        case "UPDATE_END": return .updateEnd
        case "UPDATING": return .updating(offset: u32("offset"))
        case "SET_POSITION":
            return .setPosition(
                lat: i32("lat"), lon: i32("lon"), altitude: i16("altitude"), accuracy: u16("accuracy"), age: u16("age"))
        case "SHARE": return .share(contact: addr("contact"), sharing())
        case "SHARE_GROUP": return .shareGroup(group: gid("group"), sharing())
        case "SELF":
            return .nodeSelf(NodeSelf(
                address: addr("address"), role: u8("role"), region: str("region"), power: i8("power"), time: u32("time")))
        case "CONTACT": return .contact(Contact(address: addr("address"), session: u8("session"), name: str("name")))
        case "CONTACT_GONE": return .contactGone(address: addr("address"))
        case "MESSAGE":
            return .message(Message(
                id: u32("id"), contact: addr("contact"), time: u32("time"), flags: u8("flags"), state: u8("state"),
                reason: u8("reason"), wait: u16("wait"), text: str("text")))
        case "STATE": return .state(MessageState(id: u32("id"), state: u8("state"), reason: u8("reason"), wait: u16("wait")))
        case "NEIGHBOUR":
            return .neighbour(Neighbour(
                routingId: u32("routing_id"), role: u8("role"), snrQuarterDb: i8("snr_quarter_db"), heard: u16("heard")))
        case "NEIGHBOUR_GONE": return .neighbourGone(routingId: u32("routing_id"))
        case "AIRTIME":
            return .airtime(Airtime(period: u32("period"), allowed: u32("allowed"), used: u32("used"), wait: u32("wait")))
        case "POWER": return .power(Power(millivolts: u16("millivolts"), percent: u8("percent"), flags: u8("flags")))
        case "ASKED": return .asked(address: addr("address"), why: u8("why"))
        case "GROUP": return .group(Group(group: gid("group"), name: str("name")))
        case "GROUP_GONE": return .groupGone(group: gid("group"))
        case "GROUP_MESSAGE":
            return .groupMessage(GroupMessage(
                id: u32("id"), group: gid("group"), from: u32("from"), time: u32("time"), flags: u8("flags"),
                state: u8("state"), reason: u8("reason"), wait: u16("wait"), text: str("text")))
        case "INVITE":
            return .invite(Invite(
                id: u32("id"), contact: addr("contact"), group: gid("group"), time: u32("time"), flags: u8("flags"),
                state: u8("state"), reason: u8("reason"), wait: u16("wait"), name: str("name")))
        case "POSITION": return .position(contact: addr("contact"), position())
        case "GROUP_POSITION": return .groupPosition(group: gid("group"), from: u32("from"), position())
        case "SHARING": return .sharing(contact: addr("contact"), sharing())
        case "GROUP_SHARING": return .groupSharing(group: gid("group"), sharing())
        default: throw DecodeError.undefined
        }
    }
}

/// Just enough JSON to read the vectors.
enum JSON: Decodable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    subscript(key: String) -> JSON? { if case let .object(o) = self { o[key] } else { nil } }
    var int: Int { if case let .int(i) = self { i } else { fatalError("not a whole number: \(self)") } }
    var string: String { if case let .string(s) = self { s } else { fatalError("not a string: \(self)") } }
    var array: [JSON] { if case let .array(a) = self { a } else { fatalError("not an array: \(self)") } }
    var object: [String: JSON] { if case let .object(o) = self { o } else { fatalError("not an object: \(self)") } }
    var bytes: [UInt8] { Hex.decode(string)! }
}
