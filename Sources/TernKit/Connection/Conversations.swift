// The records as a person reads them: one conversation per address and per group, each with its
// messages in order and what is unread. And `READ`, which marks every item through an id whatever
// conversation it is in, so that reading one conversation never marks another's as seen.

/// Whom a conversation is with: an address, for messages and invites, or a group.
public enum Peer: Hashable, Sendable {
    case contact(Address)
    case group(GroupID)
}

extension Item {
    /// The conversation it belongs to. An invite is between two people, so it sits with the
    /// address it went to or came from, not with the group it is to.
    public var peer: Peer {
        switch self {
        case let .message(m): .contact(m.contact)
        case let .groupMessage(m): .group(m.group)
        case let .invite(i): .contact(i.contact)
        }
    }

    /// When it was written or received, by the node's clock: 0 if the node did not know the time.
    public var time: UInt32 {
        switch self {
        case let .message(m): m.time
        case let .groupMessage(m): m.time
        case let .invite(i): i.time
        }
    }

    public var reason: UInt8 {
        switch self {
        case let .message(m): m.reason
        case let .groupMessage(m): m.reason
        case let .invite(i): i.reason
        }
    }

    public var wait: UInt16 {
        switch self {
        case let .message(m): m.wait
        case let .groupMessage(m): m.wait
        case let .invite(i): i.wait
        }
    }

    public var isReceived: Bool { state == MessageState.received }

    /// What a list shows of it: the text, or for an invite the group it is to.
    public var summary: String {
        switch self {
        case let .message(m): m.text
        case let .groupMessage(m): m.text
        case let .invite(i): "Invite to \(i.name.isEmpty ? i.group.short : i.name)"
        }
    }
}

/// One conversation: its items oldest first, and how many of them are unread.
public struct Conversation: Identifiable, Equatable, Sendable {
    public var peer: Peer
    public var name: String
    public var items: [Item]
    public var unread: Int

    public var id: Peer { peer }
    public var last: Item? { items.last }
}

extension Address {
    /// The first four bytes in hex and an ellipsis, for an address with no name.
    public var short: String { String(description.prefix(8)) + "…" }
}

/// A contact is its address: the node holds one contact for each.
extension Contact: Identifiable {
    public var id: Address { address }
}

extension GroupID {
    public var short: String { String(description.prefix(8)) + "…" }
}

extension Records {
    /// What the user calls `peer`: a contact's saved name, a group's name, or else the start of
    /// its address or id. An empty name is a name to the node, but shows as nothing, so it falls
    /// back too.
    public func name(of peer: Peer) -> String {
        switch peer {
        case let .contact(address):
            if let name = contacts[address]?.name, !name.isEmpty { return name }
            return address.short
        case let .group(group):
            if let name = groups[group]?.name, !name.isEmpty { return name }
            return group.short
        }
    }

    /// The conversation with `peer`, empty if nothing is held of it.
    public func conversation(with peer: Peer) -> Conversation {
        let items = ordered.filter { $0.peer == peer }
        return Conversation(peer: peer, name: name(of: peer), items: items, unread: items.filter(\.isUnread).count)
    }

    /// Every conversation: each address and group an item is with, and every group held even with
    /// nothing in it yet. The one with the latest item first; ids are given in order, so they say
    /// which is latest where the node's clock may not. Those with no items follow, by name.
    public var conversations: [Conversation] {
        var byPeer: [Peer: [Item]] = [:]
        for item in ordered { byPeer[item.peer, default: []].append(item) }
        for group in groups.keys where byPeer[.group(group)] == nil { byPeer[.group(group)] = [] }
        let all = byPeer.map { peer, items in
            Conversation(peer: peer, name: name(of: peer), items: items, unread: items.filter(\.isUnread).count)
        }
        return all.sorted { a, b in
            switch (a.last?.id, b.last?.id) {
            case let (x?, y?): x > y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.name < b.name
            }
        }
    }

    /// The `through` for a `READ` sent while the conversation with `peer` is on screen, or nil to
    /// send none. `READ` marks every received item through it in every conversation, so it stops
    /// short of the least unread one elsewhere: the user has not seen that. Nil when nothing here
    /// is unread, or when the first unread item here is past an unread one elsewhere, since any
    /// `READ` that marked it would mark that one too.
    public func readThrough(showing peer: Peer) -> UInt32? {
        var least: UInt32?
        var greatest: UInt32?
        var elsewhere: UInt32?
        for item in items.values where item.isUnread {
            if item.peer == peer {
                least = min(least ?? .max, item.id)
                greatest = max(greatest ?? 0, item.id)
            } else {
                elsewhere = min(elsewhere ?? .max, item.id)
            }
        }
        guard let least, let greatest else { return nil }
        // An id is at least 1, so one less than the least elsewhere does not wrap.
        let through = min(greatest, elsewhere.map { $0 - 1 } ?? greatest)
        return through >= least ? through : nil
    }

    /// The `through` to send a `READ` with, given the conversations the user has seen, each up to
    /// the greatest id it held when seen: as far up the unread items as each is in a conversation
    /// seen that far. A conversation seen while another's unread item came first is read once that
    /// one is.
    public func readThrough(seen: [Peer: UInt32]) -> UInt32? {
        var through: UInt32?
        for item in ordered where item.isUnread {
            guard let upTo = seen[item.peer], item.id <= upTo else { break }
            through = item.id
        }
        return through
    }

    /// Whether `news`, about to be applied to these records, brings a received item not seen
    /// before and not yet read: one to tell the user of. One already held, as a sync after
    /// connecting sends again, is not.
    public func isArrival(_ news: Body) -> Bool {
        let item: Item
        switch news {
        case let .message(m): item = .message(m)
        case let .groupMessage(m): item = .groupMessage(m)
        case let .invite(i): item = .invite(i)
        default: return false
        }
        return item.isUnread && items[item.id] == nil
    }
}

extension Records {
    /// Whether the node holds a message the user wrote to `peer` with `text`, under an id past
    /// `after`. A send the node never answered for may have reached it all the same; once a sync
    /// shows it did, it is not sent again. The node knows a `SEND`'s `ref` only among its last
    /// `Companion.refs` messages, so this, not the `ref`, is what keeps a late retry from sending
    /// twice.
    public func holdsSent(_ text: String, to peer: Peer, after: UInt32) -> Bool {
        items.values.contains { item in
            guard item.id > after, item.peer == peer, !item.isReceived else { return false }
            switch item {
            case let .message(m): return m.text == text
            case let .groupMessage(m): return m.text == text
            case .invite: return false
            }
        }
    }
}
