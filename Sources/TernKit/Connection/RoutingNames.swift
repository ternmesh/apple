// Names for routing ids. A neighbour, a group message's writer and a group member's position are
// known only by the four-byte routing id of draft/routing.md. A client knows whose one is only by
// working out the routing id of each address it knows, its contacts', and matching them. A group's
// is what a member claimed, not a proof: a name found for it is shown as nothing more.

extension Address {
    private static let routingIdLabel = Array("tern routing id".utf8)

    /// The routing id routing.md works out from the address: the first of the eight four-byte
    /// words of SHA-256("tern routing id" || address) that is neither 0 nor 0xFFFFFFFF. 0, which
    /// is no node's, if all eight are, which has probability 2^-248.
    public var routingId: UInt32 {
        let h = SHA256.hash(Self.routingIdLabel + bytes).bytes
        for i in stride(from: 0, to: h.count, by: 4) {
            let id = h[i ..< i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if id != 0, id != .max { return id }
        }
        return 0
    }
}

extension Records {
    /// What the user calls each contact, by its routing id, as `name(of:)` gives it. Each lookup
    /// would hash every contact, so a screen takes this once for a set of contacts.
    public var routingNames: [UInt32: String] {
        Self.byRoutingId(contacts.keys.map { ($0.routingId, name(of: .contact($0))) })
    }

    /// The names, by routing id. An id two of them share names neither, and 0 is no one's.
    static func byRoutingId(_ named: [(id: UInt32, name: String)]) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        var shared: Set<UInt32> = [0]
        for (id, name) in named where !shared.contains(id) {
            if names[id] == nil {
                names[id] = name
            } else {
                names[id] = nil
                shared.insert(id)
            }
        }
        return names
    }
}
