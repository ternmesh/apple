// Building and reading frames, field by field: big-endian numbers, signed ones in two's
// complement, 32-byte addresses and digests, and text and bytes as a length byte then the bytes.

/// Why a frame was not built. These are the caller's mistakes, not the wire's.
public enum EncodeError: Error, Equatable {
    /// Text or bytes longer than the field allows, in bytes.
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
    /// Shorter than its fields, a string or bytes longer than its field allows, a string not
    /// UTF-8, or longer than a frame may be.
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
        case .ping, .ok, .updateEnd:
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
            case let .cards(on): w.u8(on)
            case let .cardName(name): try w.str(name, limit: Companion.cardNameMax, field: "card name")
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
        case let .removeContact(address), let .endSession(address), let .contactGone(address),
             let .cardGone(address):
            w.addr(address)
        case let .makeGroup(name):
            try w.str(name, limit: Companion.nameMax, field: "name")
        case let .leaveGroup(group), let .made(group), let .groupGone(group), let .groupLink(group):
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
        case let .joinLink(link), let .link(link):
            try w.str(link, limit: Companion.linkMax, field: "link")
        case let .updateBegin(size, digest):
            w.u32(size)
            w.digest(digest)
        case let .updateData(offset, data):
            w.u32(offset)
            try w.blob(data, limit: Companion.updateChunk, field: "data")
        case let .updating(offset):
            w.u32(offset)
        case let .setPosition(lat, lon, altitude, accuracy, age):
            w.i32(lat)
            w.i32(lon)
            w.i16(altitude)
            w.u16(accuracy)
            w.u16(age)
        case let .share(contact, s), let .sharing(contact, s):
            w.addr(contact)
            w.sharing(s)
        case let .shareGroup(group, s), let .groupSharing(group, s):
            w.gid(group)
            w.sharing(s)
        case let .position(contact, p):
            w.addr(contact)
            w.position(p)
        case let .groupPosition(group, from, p):
            w.gid(group)
            w.u32(from)
            w.position(p)
        case let .error(code):
            w.u8(code)
        case let .info(version, firmware, board, release):
            w.u8(version)
            try w.str(firmware, limit: Companion.firmwareMax, field: "firmware")
            // Version 4's fields, both or neither.
            if board != nil || release != nil {
                try w.str(board ?? "", limit: Companion.boardMax, field: "board")
                try w.str(release ?? "", limit: Companion.releaseMax, field: "release")
            }
        case let .queued(id):
            w.u32(id)
        case let .nodeSelf(s):
            w.addr(s.address)
            w.u8(s.role)
            try w.str(s.region, limit: Companion.regionMax, field: "region")
            w.i8(s.power)
            w.u32(s.time)
            // Version 6's fields, both or neither.
            if s.cards != nil || s.cardName != nil {
                w.u8(s.cards ?? 0)
                try w.str(s.cardName ?? "", limit: Companion.cardNameMax, field: "card name")
            }
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
        case let .card(c):
            w.addr(c.address)
            w.u32(c.heard)
            try w.str(c.name, limit: Companion.cardNameMax, field: "name")
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
            let setting = try r.u8()
            // A setting the version spoken does not define is undefined, as a type is.
            guard Setting.since(number: setting) <= version else { throw DecodeError.undefined }
            switch setting {
            case 1: body = .set(.region(try r.str(limit: Companion.regionMax)))
            case 2: body = .set(.role(try r.u8()))
            case 3: body = .set(.power(try r.i8()))
            case 4: body = .set(.passkey(try r.u32()))
            case 5: body = .set(.cards(try r.u8()))
            case 6: body = .set(.cardName(try r.str(limit: Companion.cardNameMax)))
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
        case 0x26: body = .groupLink(group: try r.gid())
        case 0x27: body = .joinLink(link: try r.str(limit: Companion.linkMax))
        case 0x30: body = .updateBegin(size: try r.u32(), digest: try r.digest())
        case 0x31: body = .updateData(offset: try r.u32(), data: try r.blob(limit: Companion.updateChunk))
        case 0x32: body = .updateEnd
        case 0x33:
            body = .setPosition(
                lat: try r.i32(), lon: try r.i32(), altitude: try r.i16(), accuracy: try r.u16(), age: try r.u16())
        case 0x34: body = .share(contact: try r.addr(), try r.sharing())
        case 0x35: body = .shareGroup(group: try r.gid(), try r.sharing())
        case 0x40: body = .ok
        case 0x41: body = .error(code: try r.u8())
        case 0x42:
            let v = try r.u8()
            let firmware = try r.str(limit: Companion.firmwareMax)
            // `INFO` is how a client learns the node's version, so it is read by the lesser of the
            // two: a node of version 3 sends a client of version 4 neither `board` nor `release`.
            if min(v, version) >= 4 {
                body = .info(
                    version: v, firmware: firmware, board: try r.str(limit: Companion.boardMax),
                    release: try r.str(limit: Companion.releaseMax))
            } else {
                body = .info(version: v, firmware: firmware, board: nil, release: nil)
            }
        case 0x43: body = .synced(news: version >= 3 ? try r.u8() : nil)
        case 0x44: body = .queued(id: try r.u32())
        case 0x45: body = .made(group: try r.gid())
        case 0x46: body = .updating(offset: try r.u32())
        case 0x47: body = .link(link: try r.str(limit: Companion.linkMax))
        case 0x80:
            var me = NodeSelf(
                address: try r.addr(), role: try r.u8(), region: try r.str(limit: Companion.regionMax),
                power: try r.i8(), time: try r.u32())
            // A client of version 5 or earlier is sent a `SELF` that ends here.
            if version >= 6 {
                me.cards = try r.u8()
                me.cardName = try r.str(limit: Companion.cardNameMax)
            }
            body = .nodeSelf(me)
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
        case 0x8E: body = .position(contact: try r.addr(), try r.position())
        case 0x8F: body = .groupPosition(group: try r.gid(), from: try r.u32(), try r.position())
        case 0x90: body = .sharing(contact: try r.addr(), try r.sharing())
        case 0x91: body = .groupSharing(group: try r.gid(), try r.sharing())
        case 0x92:
            body = .card(Card(address: try r.addr(), heard: try r.u32(), name: try r.str(limit: Companion.cardNameMax)))
        case 0x93: body = .cardGone(address: try r.addr())
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
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    /// `SHARE`'s and `SHARING`'s fields after the contact or group.
    mutating func sharing(_ s: PositionSharing) {
        u8(s.precision)
        u8(s.fields)
        u16(s.interval)
        u16(s.minutes)
    }
    /// `POSITION`'s and `GROUP_POSITION`'s fields after the sender.
    mutating func position(_ p: Position) {
        u8(p.precision)
        i32(p.lat)
        i32(p.lon)
        i16(p.altitude)
        u8(p.accuracy)
        u32(p.age)
    }
    mutating func addr(_ a: Address) { bytes += a.bytes }
    mutating func gid(_ g: GroupID) { bytes += g.bytes }
    mutating func digest(_ d: Digest) { bytes += d.bytes }
    mutating func blob(_ b: [UInt8], limit: Int, field: String) throws {
        guard b.count <= limit else { throw EncodeError.tooLong(field: field, limit: limit) }
        bytes.append(UInt8(b.count))
        bytes += b
    }
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
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func sharing() throws -> PositionSharing {
        PositionSharing(precision: try u8(), fields: try u8(), interval: try u16(), minutes: try u16())
    }
    mutating func position() throws -> Position {
        Position(precision: try u8(), lat: try i32(), lon: try i32(), altitude: try i16(), accuracy: try u8(), age: try u32())
    }
    mutating func addr() throws -> Address { Address(Array(try take(Address.length)))! }
    mutating func gid() throws -> GroupID { GroupID(Array(try take(GroupID.length)))! }
    mutating func digest() throws -> Digest { Digest(Array(try take(Digest.length)))! }
    mutating func blob(limit: Int) throws -> [UInt8] {
        let n = Int(try u8())
        guard n <= limit else { throw DecodeError.malformed }
        return Array(try take(n))
    }
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
