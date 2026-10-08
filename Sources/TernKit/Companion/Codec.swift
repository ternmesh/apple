// Building and reading frames, field by field: big-endian numbers, 32-byte addresses, and text as
// a length byte then UTF-8.

/// Why a frame was not built. These are the caller's mistakes, not the wire's.
public enum EncodeError: Error, Equatable {
    /// Text longer than its field allows, in bytes of UTF-8.
    case tooLong(field: String, limit: Int)
    /// A frame longer than `Companion.maxFrame`.
    case frameTooLong(Int)
}

/// Why a frame could not be read.
public enum DecodeError: Error, Equatable {
    /// Shorter than a type and a sequence number: not answered at all.
    case short
    /// A type, or a setting, this version does not define.
    case undefined
    /// Shorter than its fields, a string longer than its field allows or not UTF-8, or longer
    /// than a frame may be.
    case malformed
}

extension Frame {
    /// The frame's bytes, as one Bluetooth write or notification carries them.
    public func encode() throws -> [UInt8] {
        var w = Writer()
        w.u8(body.type)
        w.u8(seq)
        switch body {
        case let .hello(version):
            w.u8(version)
        case let .sync(after):
            w.u32(after)
        case .ping, .ok:
            break
        case let .synced(news):
            if let news { w.u8(news) }
        case let .setTime(time):
            w.u32(time)
        case let .set(setting):
            w.u8(setting.number)
            switch setting {
            case let .region(name): try w.str(name, limit: Companion.regionMax, field: "region")
            case let .role(role): w.u8(role)
            case let .power(dbm): w.i8(dbm)
            case let .passkey(key): w.u32(key)
            }
        case let .send(ref, to, text):
            w.u32(ref)
            w.addr(to)
            try w.str(text, limit: Companion.textMax, field: "text")
        case let .read(through):
            w.u32(through)
        case let .saveContact(address, name):
            w.addr(address)
            try w.str(name, limit: Companion.nameMax, field: "name")
        case let .removeContact(address), let .endSession(address), let .contactGone(address):
            w.addr(address)
        case let .makeGroup(name):
            try w.str(name, limit: Companion.nameMax, field: "name")
        case let .leaveGroup(group), let .made(group), let .groupGone(group):
            w.gid(group)
        case let .nameGroup(group, name):
            w.gid(group)
            try w.str(name, limit: Companion.nameMax, field: "name")
        case let .sendGroup(ref, group, text):
            w.u32(ref)
            w.gid(group)
            try w.str(text, limit: Companion.textMax, field: "text")
        case let .sendInvite(group, to):
            w.gid(group)
            w.addr(to)
        case let .join(id):
            w.u32(id)
        case let .error(code):
            w.u8(code)
        case let .info(version, firmware):
            w.u8(version)
            try w.str(firmware, limit: Companion.firmwareMax, field: "firmware")
        case let .queued(id):
            w.u32(id)
        case let .nodeSelf(s):
            w.addr(s.address)
            w.u8(s.role)
            try w.str(s.region, limit: Companion.regionMax, field: "region")
            w.i8(s.power)
            w.u32(s.time)
        case let .contact(c):
            w.addr(c.address)
            w.u8(c.session)
            try w.str(c.name, limit: Companion.nameMax, field: "name")
        case let .message(m):
            w.u32(m.id)
            w.addr(m.contact)
            w.u32(m.time)
            w.u8(m.flags)
            w.u8(m.state)
            w.u8(m.reason)
            w.u16(m.wait)
            try w.str(m.text, limit: Companion.textMax, field: "text")
        case let .state(s):
            w.u32(s.id)
            w.u8(s.state)
            w.u8(s.reason)
            w.u16(s.wait)
        case let .neighbour(n):
            w.u32(n.routingId)
            w.u8(n.role)
            w.i8(n.snrQuarterDb)
            w.u16(n.heard)
        case let .neighbourGone(routingId):
            w.u32(routingId)
        case let .airtime(a):
            w.u32(a.period)
            w.u32(a.allowed)
            w.u32(a.used)
            w.u32(a.wait)
        case let .power(p):
            w.u16(p.millivolts)
            w.u8(p.percent)
            w.u8(p.flags)
        case let .asked(address, why):
            w.addr(address)
            w.u8(why)
        case let .group(g):
            w.gid(g.group)
            try w.str(g.name, limit: Companion.nameMax, field: "name")
        case let .groupMessage(m):
            w.u32(m.id)
            w.gid(m.group)
            w.u32(m.from)
            w.u32(m.time)
            w.u8(m.flags)
            w.u8(m.state)
            w.u8(m.reason)
            w.u16(m.wait)
            try w.str(m.text, limit: Companion.textMax, field: "text")
        case let .invite(i):
            w.u32(i.id)
            w.addr(i.contact)
            w.gid(i.group)
            w.u32(i.time)
            w.u8(i.flags)
            w.u8(i.state)
            w.u8(i.reason)
            w.u16(i.wait)
            try w.str(i.name, limit: Companion.nameMax, field: "name")
        }
        guard w.bytes.count <= Companion.maxFrame else { throw EncodeError.frameTooLong(w.bytes.count) }
        return w.bytes
    }

    /// Reads a frame by `version`, the one both ends speak. Bytes after the fields that version
    /// defines are ignored, as the specification requires: that is how a later version adds a
    /// field.
    public static func decode(_ bytes: [UInt8], version: UInt8 = Companion.version) throws -> Frame {
        guard bytes.count >= 2 else { throw DecodeError.short }
        guard bytes.count <= Companion.maxFrame else { throw DecodeError.malformed }
        // A type the version spoken does not define is undefined however its fields read.
        guard Companion.since(type: bytes[0]) <= version else { throw DecodeError.undefined }
        var r = Reader(bytes: bytes, at: 2)
        let body: Body
        switch bytes[0] {
        case 0x01: body = .hello(version: try r.u8())
        case 0x02: body = .sync(after: try r.u32())
        case 0x03: body = .ping
        case 0x04: body = .setTime(try r.u32())
        case 0x05:
            switch try r.u8() {
            case 1: body = .set(.region(try r.str(limit: Companion.regionMax)))
            case 2: body = .set(.role(try r.u8()))
            case 3: body = .set(.power(try r.i8()))
            case 4: body = .set(.passkey(try r.u32()))
            default: throw DecodeError.undefined
            }
        case 0x10:
            body = .send(ref: try r.u32(), to: try r.addr(), text: try r.str(limit: Companion.textMax))
        case 0x11: body = .read(through: try r.u32())
        case 0x18: body = .saveContact(address: try r.addr(), name: try r.str(limit: Companion.nameMax))
        case 0x19: body = .removeContact(address: try r.addr())
        case 0x1A: body = .endSession(address: try r.addr())
        case 0x20: body = .makeGroup(name: try r.str(limit: Companion.nameMax))
        case 0x21: body = .leaveGroup(group: try r.gid())
        case 0x22: body = .nameGroup(group: try r.gid(), name: try r.str(limit: Companion.nameMax))
        case 0x23: body = .sendGroup(ref: try r.u32(), group: try r.gid(), text: try r.str(limit: Companion.textMax))
        case 0x24: body = .sendInvite(group: try r.gid(), to: try r.addr())
        case 0x25: body = .join(id: try r.u32())
        case 0x40: body = .ok
        case 0x41: body = .error(code: try r.u8())
        case 0x42: body = .info(version: try r.u8(), firmware: try r.str(limit: Companion.firmwareMax))
        case 0x43: body = .synced(news: version >= 3 ? try r.u8() : nil)
        case 0x44: body = .queued(id: try r.u32())
        case 0x45: body = .made(group: try r.gid())
        case 0x80:
            body = .nodeSelf(NodeSelf(
                address: try r.addr(), role: try r.u8(), region: try r.str(limit: Companion.regionMax),
                power: try r.i8(), time: try r.u32()))
        case 0x81:
            body = .contact(Contact(address: try r.addr(), session: try r.u8(), name: try r.str(limit: Companion.nameMax)))
        case 0x82: body = .contactGone(address: try r.addr())
        case 0x83:
            body = .message(Message(
                id: try r.u32(), contact: try r.addr(), time: try r.u32(), flags: try r.u8(), state: try r.u8(),
                reason: try r.u8(), wait: try r.u16(), text: try r.str(limit: Companion.textMax)))
        case 0x84:
            body = .state(MessageState(id: try r.u32(), state: try r.u8(), reason: try r.u8(), wait: try r.u16()))
        case 0x85:
            body = .neighbour(Neighbour(routingId: try r.u32(), role: try r.u8(), snrQuarterDb: try r.i8(), heard: try r.u16()))
        case 0x86: body = .neighbourGone(routingId: try r.u32())
        case 0x87:
            body = .airtime(Airtime(period: try r.u32(), allowed: try r.u32(), used: try r.u32(), wait: try r.u32()))
        case 0x88: body = .power(Power(millivolts: try r.u16(), percent: try r.u8(), flags: try r.u8()))
        case 0x89: body = .asked(address: try r.addr(), why: try r.u8())
        case 0x8A: body = .group(Group(group: try r.gid(), name: try r.str(limit: Companion.nameMax)))
        case 0x8B: body = .groupGone(group: try r.gid())
        case 0x8C:
            body = .groupMessage(GroupMessage(
                id: try r.u32(), group: try r.gid(), from: try r.u32(), time: try r.u32(), flags: try r.u8(),
                state: try r.u8(), reason: try r.u8(), wait: try r.u16(), text: try r.str(limit: Companion.textMax)))
        case 0x8D:
            body = .invite(Invite(
                id: try r.u32(), contact: try r.addr(), group: try r.gid(), time: try r.u32(), flags: try r.u8(),
                state: try r.u8(), reason: try r.u8(), wait: try r.u16(), name: try r.str(limit: Companion.nameMax)))
        default: throw DecodeError.undefined
        }
        return Frame(seq: bytes[1], body: body)
    }

    /// The `ERROR` code a node answers a frame it could not read with, or nil if it answers
    /// nothing: a frame shorter than two bytes, or one whose type is not a request's.
    public static func errorCode(for bytes: [UInt8], _ error: DecodeError) -> UInt8? {
        guard bytes.count >= 2, bytes[0].isRequestType else { return nil }
        switch error {
        case .short: return nil
        case .undefined: return 1
        case .malformed: return 2
        }
    }
}

struct Writer {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func i8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u32(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    mutating func addr(_ a: Address) { bytes += a.bytes }
    mutating func gid(_ g: GroupID) { bytes += g.bytes }
    mutating func str(_ s: String, limit: Int, field: String) throws {
        let utf8 = Array(s.utf8)
        guard utf8.count <= limit else { throw EncodeError.tooLong(field: field, limit: limit) }
        bytes.append(UInt8(utf8.count))
        bytes += utf8
    }
}

struct Reader {
    let bytes: [UInt8]
    var at: Int

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard at + n <= bytes.count else { throw DecodeError.malformed }
        defer { at += n }
        return bytes[at..<at + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    mutating func u16() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func addr() throws -> Address { Address(Array(try take(Address.length)))! }
    mutating func gid() throws -> GroupID { GroupID(Array(try take(GroupID.length)))! }
    mutating func str(limit: Int) throws -> String {
        let n = Int(try u8())
        guard n <= limit else { throw DecodeError.malformed }
        let utf8 = try take(n)
        // The standard library repairs bad UTF-8 when it makes a String; the protocol rejects it.
        let bad = transcode(utf8.makeIterator(), from: UTF8.self, to: UTF32.self, stoppingOnError: true) { _ in }
        guard !bad else { throw DecodeError.malformed }
        return String(decoding: utf8, as: UTF8.self)
    }
}
