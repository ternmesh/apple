// What a client holds of a node: the records its news gave, kept as the specification's "What the
// node holds" says. A record replaces the one before it; STATE changes a message in place; a sync
// is the whole list of contacts, groups and neighbours, but not of messages.

/// A message, group message or invite: the three records that share the node's count of `id`s,
/// and a message's states.
public enum Item: Equatable, Sendable {
    case message(Message)
    case groupMessage(GroupMessage)
    case invite(Invite)

    public var id: UInt32 {
        switch self {
        case let .message(m): m.id
        case let .groupMessage(m): m.id
        case let .invite(i): i.id
        }
    }

    public var state: UInt8 {
        switch self {
        case let .message(m): m.state
        case let .groupMessage(m): m.state
        case let .invite(i): i.state
        }
    }

    public var flags: UInt8 {
        switch self {
        case let .message(m): m.flags
        case let .groupMessage(m): m.flags
        case let .invite(i): i.flags
        }
    }

    /// Received, and not yet marked read.
    public var isUnread: Bool { state == MessageState.received && flags & 1 == 0 }

    /// Where it is now: `STATE` replaces these three fields and no others.
    mutating func apply(_ s: MessageState) {
        switch self {
        case var .message(m):
            (m.state, m.reason, m.wait) = (s.state, s.reason, s.wait)
            self = .message(m)
        case var .groupMessage(m):
            (m.state, m.reason, m.wait) = (s.state, s.reason, s.wait)
            self = .groupMessage(m)
        case var .invite(i):
            (i.state, i.reason, i.wait) = (s.state, s.reason, s.wait)
            self = .invite(i)
        }
    }

    /// Whether it may yet change: a sync after missed news has to reach back to it. A message
    /// that is waiting or sent may be delivered; a received one still unread may be read, on
    /// another client. A group message that is sent stays sent, so only a waiting one counts.
    var mayChange: Bool {
        if isUnread { return true }
        switch self {
        case .groupMessage: return state == MessageState.waiting
        default: return state == MessageState.waiting || state == MessageState.sent
        }
    }
}

/// Everything a client has been told of one node. A value: an app keeps it between connections,
/// and on disk between runs, so that the next sync asks only for what is new.
public struct Records: Equatable, Sendable {
    public var me: NodeSelf?
    public var contacts: [Address: Contact] = [:]
    public var groups: [GroupID: Group] = [:]
    /// Messages, group messages and invites, by `id`.
    public var items: [UInt32: Item] = [:]
    public var neighbours: [UInt32: Neighbour] = [:]
    public var airtime: Airtime?
    public var power: Power?
    /// The version both ends spoke at the last sync that finished, nil if none has. A node may
    /// hold records a client of an earlier version was never sent, under `id`s below ones it was.
    public var syncedVersion: UInt8?

    /// What the sync under way has sent of the three lists a sync gives whole.
    private var syncing: (contacts: Set<Address>, groups: Set<GroupID>, neighbours: Set<UInt32>)?

    public init() {}

    public static func == (a: Records, b: Records) -> Bool {
        a.me == b.me && a.contacts == b.contacts && a.groups == b.groups && a.items == b.items
            && a.neighbours == b.neighbours && a.airtime == b.airtime && a.power == b.power
            && a.syncedVersion == b.syncedVersion
    }

    /// The items in the order the node gave them `id`s.
    public var ordered: [Item] { items.values.sorted { $0.id < $1.id } }

    /// Takes one news frame in. News that is not a record of anything (`ASKED`) changes nothing.
    public mutating func apply(_ news: Body) {
        switch news {
        case let .nodeSelf(s):
            me = s
        case let .contact(c):
            contacts[c.address] = c
            syncing?.contacts.insert(c.address)
        case let .contactGone(address):
            contacts[address] = nil
        case let .group(g):
            groups[g.group] = g
            syncing?.groups.insert(g.group)
        case let .groupGone(group):
            groups[group] = nil
        case let .message(m):
            items[m.id] = .message(m)
        case let .groupMessage(m):
            items[m.id] = .groupMessage(m)
        case let .invite(i):
            items[i.id] = .invite(i)
        case let .state(s):
            items[s.id]?.apply(s)
        case let .neighbour(n):
            neighbours[n.routingId] = n
            syncing?.neighbours.insert(n.routingId)
        case let .neighbourGone(routingId):
            neighbours[routingId] = nil
        case let .airtime(a):
            airtime = a
        case let .power(p):
            power = p
        default:
            break
        }
    }

    /// The `after` to sync with. Normally the greatest `id` held. After missed news, one less than
    /// the least `id` whose state may have changed unseen, and never more than `missedSince`, the
    /// greatest `id` held when news was first missed: what was lost may be below records received
    /// after it. Speaking a later version to the node than at the last sync, 0, once.
    public func after(version: UInt8, missedSince: UInt32? = nil) -> UInt32 {
        guard let synced = syncedVersion, synced >= version else { return 0 }
        guard let floor = missedSince else { return greatest }
        let least = items.values.filter(\.mayChange).map(\.id).min()
        return min(floor, least.map { $0 - 1 } ?? floor)
    }

    /// The greatest `id` held, 0 for none.
    public var greatest: UInt32 { items.keys.max() ?? 0 }

    mutating func beginSync() {
        syncing = ([], [], [])
    }

    /// `SYNCED`: whatever of the three whole lists the sync did not send is gone. Returns false,
    /// and changes nothing, for a sync abandoned on the way.
    mutating func finishSync(version: UInt8) -> Bool {
        guard let seen = syncing else { return false }
        contacts = contacts.filter { seen.contacts.contains($0.key) }
        groups = groups.filter { seen.groups.contains($0.key) }
        neighbours = neighbours.filter { seen.neighbours.contains($0.key) }
        syncedVersion = version
        syncing = nil
        return true
    }

    /// A sync that never finished proves nothing about what is gone.
    mutating func abandonSync() {
        syncing = nil
    }
}
