// The companion protocol's frames, version 4: draft/companion.md in ternmesh/spec.
//
// Nothing here touches Bluetooth or a screen. It builds frames and reads them, and
// Tests/TernKitTests holds it to the specification's vectors.

/// The protocol's numbers, as the specification's Parameters give them.
public enum Companion {
    /// The version this client speaks. Version 3 is this without updates (the requests `0x30` to
    /// `0x32`, `UPDATING`, errors 10 and 11, and `INFO`'s `board` and `release`), version 2 is
    /// version 3 without `SYNCED`'s `news`, version 1 is version 2 without groups, and version 0
    /// is version 1 without `END_SESSION` and `ASKED`.
    public static let version: UInt8 = 4

    /// The least version that defines the frame type `type`.
    public static func since(type: UInt8) -> UInt8 {
        switch type {
        case 0x1A, 0x89: 1
        case 0x20...0x25, 0x45, 0x8A...0x8D: 2
        case 0x30...0x32, 0x46: 4
        default: 0
        }
    }
    public static let maxFrame = 180
    public static let textMax = 128
    public static let nameMax = 31
    public static let regionMax = 15
    public static let firmwareMax = 31
    /// `INFO`'s `board` and `release`.
    public static let boardMax = 31
    public static let releaseMax = 31
    /// The longest `data` an `UPDATE_DATA` carries, and what a client sends in all but the last.
    public static let updateChunk = 172
    /// How long a client waits for an answer, in seconds.
    public static let answerWait = 5.0
    /// The longest a client goes without a request, in seconds.
    public static let idle = 20.0
    /// How long a node on a serial port waits for a request before it takes the client for gone.
    public static let lapse = 60.0
    /// How long a byte stream may stall mid-frame before what is held is text, in seconds.
    public static let gap = 0.5
    /// How many of its last messages a node matches a `SEND`'s `ref` against.
    public static let refs = 16
    /// The least time between two `ASKED`s for one address, or two of `NEIGHBOUR`, `AIRTIME` or
    /// `POWER`, in seconds.
    public static let quiet = 10.0

    /// The GATT service a node offers, and its two characteristics.
    public static let service = "7A280001-EB17-4C1C-889B-1741DD50FF40"
    public static let toNode = "7A280002-EB17-4C1C-889B-1741DD50FF40"
    public static let fromNode = "7A280003-EB17-4C1C-889B-1741DD50FF40"
    /// The least ATT MTU a client asks for: a 180-byte frame and the 3 bytes ATT adds.
    public static let minMTU = 183
}

/// A node's address: an Ed25519 public key.
public struct Address: Hashable, Sendable, CustomStringConvertible {
    public static let length = 32
    public let bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == Address.length else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        guard let bytes = Hex.decode(hex) else { return nil }
        self.init(bytes)
    }

    public var description: String { Hex.encode(bytes) }
}

/// A group's id, which the node works out from the group's secret. A client never holds the
/// secret: no frame carries it.
public struct GroupID: Hashable, Sendable, CustomStringConvertible {
    public static let length = 8
    public let bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == GroupID.length else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        guard let bytes = Hex.decode(hex) else { return nil }
        self.init(bytes)
    }

    public var description: String { Hex.encode(bytes) }
}

/// A SHA-256 digest, as `UPDATE_BEGIN` carries an image's.
public struct Digest: Hashable, Sendable, CustomStringConvertible {
    public static let length = 32
    public let bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == Digest.length else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        guard let bytes = Hex.decode(hex) else { return nil }
        self.init(bytes)
    }

    public var description: String { Hex.encode(bytes) }
}

/// An `ERROR`'s code. A code this client does not know is a refusal all the same.
public enum ErrorCode {
    /// A request, or a setting, the node's version does not define.
    public static let undefined: UInt8 = 1
    public static let malformed: UInt8 = 2
    /// A value the node refuses: a region it does not have, a power it cannot send at, empty text.
    public static let refused: UInt8 = 3
    /// Not a valid address, or the node's own.
    public static let badAddress: UInt8 = 4
    /// The node cannot hold another contact, message or group, or the image an update offers. A
    /// node whose `board` is empty answers `UPDATE_BEGIN` with it.
    public static let noRoom: UInt8 = 5
    /// `HELLO` first: on a connection that had one, the node has taken the client for gone.
    public static let helloFirst: UInt8 = 6
    /// The Bluetooth link's MTU is too small.
    public static let mtu: UInt8 = 7
    /// Not now: the node is finishing something else.
    public static let notNow: UInt8 = 8
    /// A group the node is not in, or an invite it does not hold.
    public static let notHeld: UInt8 = 9
    /// Not where the update is: none is under way, or not at that offset. `UPDATE_BEGIN` again
    /// says where to go on from.
    public static let notThere: UInt8 = 10
    /// Not an image this node runs, or its digest is wrong: the update is discarded.
    public static let notAnImage: UInt8 = 11
}

/// A frame: its sequence number and what it says. The type byte follows from the body.
public struct Frame: Equatable, Sendable {
    public var seq: UInt8
    public var body: Body

    public init(seq: UInt8, body: Body) {
        self.seq = seq
        self.body = body
    }
}

/// One of `SET`'s settings, with its value.
public enum Setting: Equatable, Sendable {
    case region(String)
    case role(UInt8)
    case power(Int8)
    /// 0 to 999999, or 0xFFFFFFFF for a random one each time.
    case passkey(UInt32)

    var number: UInt8 {
        switch self {
        case .region: 1
        case .role: 2
        case .power: 3
        case .passkey: 4
        }
    }
}

/// `SELF`: the node itself.
public struct NodeSelf: Equatable, Sendable {
    public var address: Address
    /// 0 a leaf, 1 a relay.
    public var role: UInt8
    /// A profile's name, such as `EU868`, or empty.
    public var region: String
    /// The most it transmits at, in dBm.
    public var power: Int8
    /// Its clock, in seconds since 1970; 0 if it does not know.
    public var time: UInt32

    public init(address: Address, role: UInt8, region: String, power: Int8, time: UInt32) {
        self.address = address
        self.role = role
        self.region = region
        self.power = power
        self.time = time
    }
}

/// `CONTACT`: an address the user saved, with a name.
public struct Contact: Equatable, Sendable {
    public var address: Address
    /// 1 if the node shares a session with it.
    public var session: UInt8
    public var name: String

    public init(address: Address, session: UInt8, name: String) {
        self.address = address
        self.session = session
        self.name = name
    }
}

/// `STATE`: where a message is, and what it waits for.
public struct MessageState: Equatable, Sendable {
    public var id: UInt32
    public var state: UInt8
    public var reason: UInt8
    /// Seconds until it goes, by the node's estimate; 0 for none.
    public var wait: UInt16

    public init(id: UInt32, state: UInt8, reason: UInt8, wait: UInt16) {
        self.id = id
        self.state = state
        self.reason = reason
        self.wait = wait
    }

    public static let waiting: UInt8 = 0
    public static let sent: UInt8 = 1
    public static let delivered: UInt8 = 2
    public static let notDelivered: UInt8 = 3
    public static let received: UInt8 = 4
}

/// `MESSAGE`: one message, the whole of it.
public struct Message: Equatable, Sendable {
    public var id: UInt32
    /// Whom it went to or came from.
    public var contact: Address
    public var time: UInt32
    /// Bit 0: a received message has been read.
    public var flags: UInt8
    public var state: UInt8
    public var reason: UInt8
    public var wait: UInt16
    public var text: String

    public init(
        id: UInt32, contact: Address, time: UInt32, flags: UInt8, state: UInt8, reason: UInt8,
        wait: UInt16, text: String
    ) {
        self.id = id
        self.contact = contact
        self.time = time
        self.flags = flags
        self.state = state
        self.reason = reason
        self.wait = wait
        self.text = text
    }
}

/// `GROUP`: a group the node holds, with the user's name for it.
public struct Group: Equatable, Sendable {
    public var group: GroupID
    public var name: String

    public init(group: GroupID, name: String) {
        self.group = group
        self.name = name
    }
}

/// `GROUP_MESSAGE`: one message written to a group or received from one. Its `id` is from the
/// same count as a `MESSAGE`'s.
public struct GroupMessage: Equatable, Sendable {
    public var id: UInt32
    public var group: GroupID
    /// The routing id its writer claimed, 0 for one this node wrote. A claim, not a proof.
    public var from: UInt32
    public var time: UInt32
    /// Bit 0: a received message has been read.
    public var flags: UInt8
    public var state: UInt8
    public var reason: UInt8
    public var wait: UInt16
    public var text: String

    public init(
        id: UInt32, group: GroupID, from: UInt32, time: UInt32, flags: UInt8, state: UInt8, reason: UInt8,
        wait: UInt16, text: String
    ) {
        self.id = id
        self.group = group
        self.from = from
        self.time = time
        self.flags = flags
        self.state = state
        self.reason = reason
        self.wait = wait
        self.text = text
    }
}

/// `INVITE`: an invite to a group, sent to `contact` or received from it. It goes as a unicast
/// message does, and has a message's states.
public struct Invite: Equatable, Sendable {
    public var id: UInt32
    public var contact: Address
    public var group: GroupID
    public var time: UInt32
    /// Bit 0: a received invite has been read.
    public var flags: UInt8
    public var state: UInt8
    public var reason: UInt8
    public var wait: UInt16
    /// What the inviter calls the group.
    public var name: String

    public init(
        id: UInt32, contact: Address, group: GroupID, time: UInt32, flags: UInt8, state: UInt8, reason: UInt8,
        wait: UInt16, name: String
    ) {
        self.id = id
        self.contact = contact
        self.group = group
        self.time = time
        self.flags = flags
        self.state = state
        self.reason = reason
        self.wait = wait
        self.name = name
    }
}

/// `NEIGHBOUR`: a node whose announces this one hears.
public struct Neighbour: Equatable, Sendable {
    public var routingId: UInt32
    public var role: UInt8
    /// The last frame's signal-to-noise ratio, in quarters of a dB.
    public var snrQuarterDb: Int8
    /// Seconds since it was heard, as of the record.
    public var heard: UInt16

    public init(routingId: UInt32, role: UInt8, snrQuarterDb: Int8, heard: UInt16) {
        self.routingId = routingId
        self.role = role
        self.snrQuarterDb = snrQuarterDb
        self.heard = heard
    }
}

/// `AIRTIME`: the region's limit on transmitting, as the node is spending it.
public struct Airtime: Equatable, Sendable {
    /// Seconds; 0 for a profile with no limit.
    public var period: UInt32
    /// Milliseconds.
    public var allowed: UInt32
    public var used: UInt32
    public var wait: UInt32

    public init(period: UInt32, allowed: UInt32, used: UInt32, wait: UInt32) {
        self.period = period
        self.allowed = allowed
        self.used = used
        self.wait = wait
    }
}

/// `POWER`: the node's battery.
public struct Power: Equatable, Sendable {
    /// 0 if it cannot measure it.
    public var millivolts: UInt16
    /// 255 if it has no estimate.
    public var percent: UInt8
    /// Bit 0 charging, bit 1 on external power.
    public var flags: UInt8

    public init(millivolts: UInt16, percent: UInt8, flags: UInt8) {
        self.millivolts = millivolts
        self.percent = percent
        self.flags = flags
    }
}

/// What a frame says: every frame of version 4.
public enum Body: Equatable, Sendable {
    // Requests, sent by the client.
    case hello(version: UInt8)
    case sync(after: UInt32)
    case ping
    case setTime(UInt32)
    case set(Setting)
    case send(ref: UInt32, to: Address, text: String)
    case read(through: UInt32)
    case saveContact(address: Address, name: String)
    case removeContact(address: Address)
    case endSession(address: Address)
    case makeGroup(name: String)
    case leaveGroup(group: GroupID)
    case nameGroup(group: GroupID, name: String)
    case sendGroup(ref: UInt32, group: GroupID, text: String)
    case sendInvite(group: GroupID, to: Address)
    case join(id: UInt32)
    /// An image of `size` bytes, whose SHA-256 is `digest`, follows.
    case updateBegin(size: UInt32, digest: Digest)
    /// The image's bytes from `offset`: `Companion.updateChunk` of them, all but the last.
    case updateData(offset: UInt32, data: [UInt8])
    /// Run the image. Never sent again once given up on: the node may be restarting into it.
    case updateEnd

    // Answers, sent by the node with the request's seq.
    case ok
    case error(code: UInt8)
    /// `board` and `release` are nil from a node, or to a client, of version 3 or earlier, whose
    /// `INFO` has neither. `board` is empty if the node cannot be updated over this protocol, and
    /// `release` if its firmware has no version, as a build made by hand may not.
    case info(version: UInt8, firmware: String, board: String?, release: String?)
    /// The sync is done. `news` is the node's count as it answers, the `seq` of its next news
    /// frame; nil from a node of version 2 or earlier, whose `SYNCED` has no fields.
    case synced(news: UInt8?)
    case queued(id: UInt32)
    case made(group: GroupID)
    /// The offset an update goes on from.
    case updating(offset: UInt32)

    // News, sent by the node with its count as seq.
    case nodeSelf(NodeSelf)
    case contact(Contact)
    case contactGone(address: Address)
    case message(Message)
    case state(MessageState)
    case neighbour(Neighbour)
    case neighbourGone(routingId: UInt32)
    case airtime(Airtime)
    case power(Power)
    /// The node refused first contact from `address`, which proved itself: `why` is 1 if it is
    /// not a contact, 2 if the node has no room for another session.
    case asked(address: Address, why: UInt8)
    case group(Group)
    case groupGone(group: GroupID)
    case groupMessage(GroupMessage)
    case invite(Invite)

    /// The type byte.
    public var type: UInt8 {
        switch self {
        case .hello: 0x01
        case .sync: 0x02
        case .ping: 0x03
        case .setTime: 0x04
        case .set: 0x05
        case .send: 0x10
        case .read: 0x11
        case .saveContact: 0x18
        case .removeContact: 0x19
        case .endSession: 0x1A
        case .makeGroup: 0x20
        case .leaveGroup: 0x21
        case .nameGroup: 0x22
        case .sendGroup: 0x23
        case .sendInvite: 0x24
        case .join: 0x25
        case .updateBegin: 0x30
        case .updateData: 0x31
        case .updateEnd: 0x32
        case .ok: 0x40
        case .error: 0x41
        case .info: 0x42
        case .synced: 0x43
        case .queued: 0x44
        case .made: 0x45
        case .updating: 0x46
        case .nodeSelf: 0x80
        case .contact: 0x81
        case .contactGone: 0x82
        case .message: 0x83
        case .state: 0x84
        case .neighbour: 0x85
        case .neighbourGone: 0x86
        case .airtime: 0x87
        case .power: 0x88
        case .asked: 0x89
        case .group: 0x8A
        case .groupGone: 0x8B
        case .groupMessage: 0x8C
        case .invite: 0x8D
        }
    }

    /// The specification's name for the frame, such as `SELF`.
    public var name: String {
        switch self {
        case .hello: "HELLO"
        case .sync: "SYNC"
        case .ping: "PING"
        case .setTime: "SET_TIME"
        case .set: "SET"
        case .send: "SEND"
        case .read: "READ"
        case .saveContact: "SAVE_CONTACT"
        case .removeContact: "REMOVE_CONTACT"
        case .endSession: "END_SESSION"
        case .makeGroup: "MAKE_GROUP"
        case .leaveGroup: "LEAVE_GROUP"
        case .nameGroup: "NAME_GROUP"
        case .sendGroup: "SEND_GROUP"
        case .sendInvite: "SEND_INVITE"
        case .join: "JOIN"
        case .updateBegin: "UPDATE_BEGIN"
        case .updateData: "UPDATE_DATA"
        case .updateEnd: "UPDATE_END"
        case .ok: "OK"
        case .error: "ERROR"
        case .info: "INFO"
        case .synced: "SYNCED"
        case .queued: "QUEUED"
        case .made: "MADE"
        case .updating: "UPDATING"
        case .nodeSelf: "SELF"
        case .contact: "CONTACT"
        case .contactGone: "CONTACT_GONE"
        case .message: "MESSAGE"
        case .state: "STATE"
        case .neighbour: "NEIGHBOUR"
        case .neighbourGone: "NEIGHBOUR_GONE"
        case .airtime: "AIRTIME"
        case .power: "POWER"
        case .asked: "ASKED"
        case .group: "GROUP"
        case .groupGone: "GROUP_GONE"
        case .groupMessage: "GROUP_MESSAGE"
        case .invite: "INVITE"
        }
    }
}

extension Body {
    /// The least version that defines this frame: a client sends no request the node's version
    /// does not define, and reads no frame the version both ends speak does not.
    public var since: UInt8 { Companion.since(type: type) }
}

public extension UInt8 {
    var isRequestType: Bool { (0x01...0x3F).contains(self) }
    var isAnswerType: Bool { (0x40...0x7F).contains(self) }
    var isNewsType: Bool { (0x80...0xBF).contains(self) }
}

enum Hex {
    static func encode(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return out
    }

    static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
