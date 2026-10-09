// The companion protocol's frames, version 7: draft/companion.md in ternmesh/spec.
//
// Nothing here touches Bluetooth or a screen. It builds frames and reads them, and
// Tests/TernKitTests holds it to the specification's vectors.

/// The protocol's numbers, as the specification's Parameters give them.
public enum Companion {
    /// The version this client speaks. Version 6 is this without join codes (the requests
    /// `GROUP_LINK` and `JOIN_LINK`, and the answer `LINK`), version 5 is version 6 without cards (the settings 5 and 6,
    /// `SELF`'s `cards` and `card_name`, and the news `CARD` and `CARD_GONE`), version 4 is
    /// version 5 without positions (the requests `0x33` to `0x35`, error 12, and the news
    /// `POSITION`, `GROUP_POSITION`, `SHARING` and `GROUP_SHARING`), version 3 is version 4
    /// without updates (the requests `0x30` to `0x32`, `UPDATING`, errors 10 and 11, and `INFO`'s
    /// `board` and `release`), version 2 is version 3 without `SYNCED`'s `news`, version 1 is
    /// version 2 without groups, and version 0 is version 1 without `END_SESSION` and `ASKED`.
    public static let version: UInt8 = 7

    /// The least version that defines the frame type `type`.
    public static func since(type: UInt8) -> UInt8 {
        switch type {
        case 0x1A, 0x89: 1
        case 0x20...0x25, 0x45, 0x8A...0x8D: 2
        case 0x30...0x32, 0x46: 4
        case 0x33...0x35, 0x8E...0x91: 5
        case 0x92...0x93: 6
        case 0x26...0x27, 0x47: 7
        default: 0
        }
    }
    public static let maxFrame = 180
    public static let textMax = 128
    public static let nameMax = 31
    /// A join code's link, the longest: a group whose name is 31 bytes.
    public static let linkMax = 102
    /// The name a node's cards carry, and the one a card held carried.
    public static let cardNameMax = 31
    public static let regionMax = 15
    public static let firmwareMax = 31
    /// `INFO`'s `board` and `release`.
    public static let boardMax = 31
    public static let releaseMax = 31
    /// The finest precision a position is shared at: a cell of `360 / 2^24` degrees.
    public static let precisionMax: UInt8 = 24
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

/// A group's id, which the node works out from the group's secret. No frame carries the secret but
/// a join code's, in `LINK` and `JOIN_LINK`, which a client passes on and does not keep.
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
    /// Not a contact: `SHARE` to an address the node does not hold as one.
    public static let notAContact: UInt8 = 12
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
    /// 1 to send cards, 0 to send none: a node refuses any other value. Only as the user asks.
    case cards(UInt8)
    /// The name the node's cards carry, empty for none: the one name a node puts on the air in
    /// clear. Only as the user asks.
    case cardName(String)

    var number: UInt8 {
        switch self {
        case .region: 1
        case .role: 2
        case .power: 3
        case .passkey: 4
        case .cards: 5
        case .cardName: 6
        }
    }

    /// The least version that defines the setting.
    public var since: UInt8 { Setting.since(number: number) }

    static func since(number: UInt8) -> UInt8 {
        switch number {
        case 5, 6: 6
        default: 0
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
    /// 1 if the node sends cards, 0 if not, and the name its cards carry, as `SET` 5 and 6 set
    /// them. From a `SELF` of version 6 or later: both nil before, when the node has no cards to
    /// set.
    public var cards: UInt8?
    public var cardName: String?

    public init(
        address: Address, role: UInt8, region: String, power: Int8, time: UInt32, cards: UInt8? = nil,
        cardName: String? = nil
    ) {
        self.address = address
        self.role = role
        self.region = region
        self.power = power
        self.time = time
        self.cards = cards
        self.cardName = cardName
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

/// `POSITION` and `GROUP_POSITION`: a position the node holds from a contact, or from a routing
/// id in a group, as the centre of its cell.
public struct Position: Equatable, Sendable {
    /// The cell is `360 / 2^precision` degrees each way. 0 in a record that says the node holds
    /// no position from that sender, whose other fields are then 0.
    public var precision: UInt8
    /// The cell's centre, in 10^-7 degree, north and east positive.
    public var lat: Int32
    public var lon: Int32
    /// Metres, or `Position.noAltitude`.
    public var altitude: Int16
    /// Metres; 0 if the position gave none.
    public var accuracy: UInt8
    /// How many seconds old the fix was, as of the record.
    public var age: UInt32

    public init(precision: UInt8, lat: Int32, lon: Int32, altitude: Int16, accuracy: UInt8, age: UInt32) {
        self.precision = precision
        self.lat = lat
        self.lon = lon
        self.altitude = altitude
        self.accuracy = accuracy
        self.age = age
    }

    /// An `altitude` that says there is none.
    public static let noAltitude = Int16.min
    /// The record that says the node holds no position from that sender.
    public static let notHeld = Position(precision: 0, lat: 0, lon: 0, altitude: 0, accuracy: 0, age: 0)
}

/// How the node shares its position with a contact or a group: what `SHARE` and `SHARE_GROUP`
/// ask for, and `SHARING` and `GROUP_SHARING` say. Not `Sharing`, which shares an address.
public struct PositionSharing: Equatable, Sendable {
    /// 1 to 24, or 0 for off, when the other fields are 0.
    public var precision: UInt8
    /// Bit 0: altitude goes with each position. Bit 1: accuracy does.
    public var fields: UInt8
    /// Seconds between positions.
    public var interval: UInt16
    /// In news, the minutes left until the node turns sharing off, rounded up; in a request, how
    /// long it lasts from now. 0 for until it is turned off.
    public var minutes: UInt16

    public init(precision: UInt8, fields: UInt8, interval: UInt16, minutes: UInt16) {
        self.precision = precision
        self.fields = fields
        self.interval = interval
        self.minutes = minutes
    }

    public static let altitude: UInt8 = 1
    public static let accuracy: UInt8 = 2
    /// Sharing turned off, or asked off.
    public static let off = PositionSharing(precision: 0, fields: 0, interval: 0, minutes: 0)

    public var isOn: Bool { precision != 0 }
}

/// `CARD`: a card the node holds, one for each address. Who is about.
public struct Card: Equatable, Sendable {
    public var address: Address
    /// Seconds since the node accepted the card, as of the record.
    public var heard: UInt32
    /// The name the card carried: a claim its sender made, not a name the user gave. May be empty.
    public var name: String

    public init(address: Address, heard: UInt32, name: String) {
        self.address = address
        self.heard = heard
        self.name = name
    }
}

/// What a frame says: every frame of version 7.
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
    /// The join code of `group`, which the node answers with `LINK`. Only ever what the user asked
    /// to see or share.
    case groupLink(group: GroupID)
    /// Join the group a join code is for, which the node answers with `MADE`. Only ever a code the
    /// user asked to join from.
    case joinLink(link: String)
    /// An image of `size` bytes, whose SHA-256 is `digest`, follows.
    case updateBegin(size: UInt32, digest: Digest)
    /// The image's bytes from `offset`: `Companion.updateChunk` of them, all but the last.
    case updateData(offset: UInt32, data: [UInt8])
    /// Run the image. Never sent again once given up on: the node may be restarting into it.
    case updateEnd
    /// The client's position: `lat` and `lon` in 10^-7 degree, WGS 84; `altitude` in metres, or
    /// `Position.noAltitude`; `accuracy` in metres, 0 for none; `age` in seconds.
    case setPosition(lat: Int32, lon: Int32, altitude: Int16, accuracy: UInt16, age: UInt16)
    /// Sharing with a contact turned on, changed, or with `PositionSharing.off`, turned off. Only
    /// ever at the user's asking.
    case share(contact: Address, PositionSharing)
    case shareGroup(group: GroupID, PositionSharing)

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
    /// A group's join code, which `GROUP_LINK` asked for: the group's secret, shown and let go.
    case link(link: String)

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
    /// The position the node holds from `contact`; `Position.notHeld` once it holds none.
    case position(contact: Address, Position)
    /// The position the node holds from the routing id `from` in a group: what a member claimed.
    case groupPosition(group: GroupID, from: UInt32, Position)
    /// How the node shares its position with `contact`; `PositionSharing.off` once it does not.
    case sharing(contact: Address, PositionSharing)
    case groupSharing(group: GroupID, PositionSharing)
    /// A card the node holds, from the address in it.
    case card(Card)
    /// The node forgot the card it held from `address`.
    case cardGone(address: Address)

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
        case .groupLink: 0x26
        case .joinLink: 0x27
        case .updateBegin: 0x30
        case .updateData: 0x31
        case .updateEnd: 0x32
        case .setPosition: 0x33
        case .share: 0x34
        case .shareGroup: 0x35
        case .ok: 0x40
        case .error: 0x41
        case .info: 0x42
        case .synced: 0x43
        case .queued: 0x44
        case .made: 0x45
        case .updating: 0x46
        case .link: 0x47
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
        case .position: 0x8E
        case .groupPosition: 0x8F
        case .sharing: 0x90
        case .groupSharing: 0x91
        case .card: 0x92
        case .cardGone: 0x93
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
        case .groupLink: "GROUP_LINK"
        case .joinLink: "JOIN_LINK"
        case .updateBegin: "UPDATE_BEGIN"
        case .updateData: "UPDATE_DATA"
        case .updateEnd: "UPDATE_END"
        case .setPosition: "SET_POSITION"
        case .share: "SHARE"
        case .shareGroup: "SHARE_GROUP"
        case .ok: "OK"
        case .error: "ERROR"
        case .info: "INFO"
        case .synced: "SYNCED"
        case .queued: "QUEUED"
        case .made: "MADE"
        case .updating: "UPDATING"
        case .link: "LINK"
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
        case .position: "POSITION"
        case .groupPosition: "GROUP_POSITION"
        case .sharing: "SHARING"
        case .groupSharing: "GROUP_SHARING"
        case .card: "CARD"
        case .cardGone: "CARD_GONE"
        }
    }
}

extension Body {
    /// The least version that defines this frame, and for a `SET` its setting: a client sends no
    /// request the node's version does not define, and reads no frame the version both ends speak
    /// does not.
    public var since: UInt8 {
        if case let .set(setting) = self { return max(Companion.since(type: type), setting.since) }
        return Companion.since(type: type)
    }
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
