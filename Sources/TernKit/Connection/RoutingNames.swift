// Names for routing ids. A neighbour, a group message's writer and a group member's position are
// known only by the four-byte routing id of draft/routing.md. A client knows whose one is only by
// working out the routing id of each address it knows, its contacts', and matching them. A group's
// is what a member claimed, not a proof: a name found for it is shown as nothing more. A node whose
// card the node holds is known by that card's address too, but its name is only what it claims, so
// a contact's name comes first.
//
// How a routing id is made depends on the node's version. From version 14, announces carry a key
// blinded from the address, not the address, and the id is made from that key:
//
//   h  = SHA-512("tern v0 blind" || A || u32be(0)) mod L
//   B  = [h] A
//   id = the first of SHA-256("tern routing id" || B)'s eight u32s that is neither 0 nor 0xFFFFFFFF
//
// A node of version 13 or earlier makes it from the address itself, A in place of B. A client
// works ids out as the node's version makes them: an id of the other kind matches no one.
// Blinding costs a scalar multiplication, so each address's blinded id is worked out once and kept.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The first version whose routing ids are made from the blinded key.
public enum RoutingIds {
    public static let blindedSince: UInt8 = 14
    /// e, the epoch, which routing.md fixes at 0: a node's routing id does not change.
    static let epoch: UInt32 = 0
    private static let blindLabel = Array("tern v0 blind".utf8)
    private static let idLabel = Array("tern routing id".utf8)

    /// Whether a node of `version` gives blinded routing ids.
    public static func blinded(version: UInt8?) -> Bool { (version ?? 0) >= blindedSince }

    /// h, the blinding scalar for `address`, reduced mod L: 32 bytes, little-endian.
    static func blind(_ address: [UInt8]) -> [UInt8] {
        let e = [UInt8(epoch >> 24 & 0xFF), UInt8(epoch >> 16 & 0xFF), UInt8(epoch >> 8 & 0xFF), UInt8(epoch & 0xFF)]
        return Ed25519.reduce(Ed25519.sha512(blindLabel + address + e))
    }

    /// The routing id of a key, the address itself before version 14 and the blinded key from it:
    /// 0, which is no node's, if all eight words are reserved, which has probability 2^-248.
    static func id(ofKey key: [UInt8]) -> UInt32 {
        let h = SHA256.hash(idLabel + key).bytes
        for i in stride(from: 0, to: h.count, by: 4) {
            let id = h[i ..< i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if id != 0, id != .max { return id }
        }
        return 0
    }

    /// The blinded ids worked out so far, by address. Shared by every screen and every node's
    /// records: an address's id is the same whichever node it is matched for.
    private static let cache = Cache()

    static func blindedId(_ address: Address) -> UInt32 {
        if let id = cache[address] { return id }
        let id = address.routingKey.map(id(ofKey:)) ?? 0
        cache[address] = id
        return id
    }

    private final class Cache: @unchecked Sendable {
        private var ids: [Address: UInt32] = [:]
        private var lock = pthread_mutex_t()

        init() { pthread_mutex_init(&lock, nil) }

        subscript(address: Address) -> UInt32? {
            get {
                pthread_mutex_lock(&lock)
                defer { pthread_mutex_unlock(&lock) }
                return ids[address]
            }
            set {
                pthread_mutex_lock(&lock)
                defer { pthread_mutex_unlock(&lock) }
                ids[address] = newValue
            }
        }
    }
}

extension Address {
    /// The routing key routing.md blinds from the address, `[h] A`: nil for an address that is not
    /// valid (of small order, with a part of small order, or not a point), which has no routing id.
    public var routingKey: [UInt8]? {
        Ed25519.multiply(RoutingIds.blind(bytes), bytes)
    }

    /// The routing id a node of `version` gives the node at this address: from its blinded key
    /// for a node of version 14 or later, kept once worked out, and from the address itself before.
    /// 0, which is no node's, for an address that has none.
    public func routingId(version: UInt8?) -> UInt32 {
        RoutingIds.blinded(version: version) ? RoutingIds.blindedId(self) : unblindedRoutingId
    }

    /// The routing id a node of version 13 or earlier makes from the address itself.
    public var unblindedRoutingId: UInt32 { RoutingIds.id(ofKey: bytes) }
}

extension Records {
    /// The version the records' routing ids were made by: the one both ends spoke at the last
    /// sync, which is 14 or later exactly when the node's is, since this client speaks 14.
    public var routingVersion: UInt8? { syncedVersion }

    /// The routing id the node these records are of gives `address`.
    public func routingId(of address: Address) -> UInt32 { address.routingId(version: routingVersion) }

    /// What the user calls each contact, by its routing id, as `name(of:)` gives it. Each lookup
    /// would work out every contact's id, so a screen takes this once for a set of contacts.
    public var routingNames: [UInt32: String] {
        Self.byRoutingId(contacts.keys.map { (routingId(of: $0), name(of: .contact($0))) })
    }

    /// The cards held, by the routing id of the address each is from, for an id no contact has: a
    /// contact's name is the user's own, and comes before what a card claims. As with
    /// `routingNames`, a screen takes this once.
    public var routingCards: [UInt32: Card] {
        let named = Set(contacts.keys.map(routingId(of:)))
        return Self.byRoutingId(cards.values.map { (routingId(of: $0.address), $0) }).filter { !named.contains($0.key) }
    }

    /// The contact whose routing id is `id`, if exactly one has it.
    public func contact(routingId id: UInt32) -> Address? {
        let matching = contacts.keys.filter { routingId(of: $0) == id }
        return id != 0 && matching.count == 1 ? matching[0] : nil
    }

    /// The names, or cards, by routing id. An id two of them share names neither, and 0 is no one's.
    static func byRoutingId<Name>(_ named: [(id: UInt32, name: Name)]) -> [UInt32: Name] {
        var names: [UInt32: Name] = [:]
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
