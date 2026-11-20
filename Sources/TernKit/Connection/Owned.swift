// The nodes this client's node is an owner of, as far as it knows: draft/managing.md in
// ternmesh/spec. A node says so in a notice when its owners change (`OWNER_CHANGED` news whose
// `contact` is this client's node), and by answering a request to manage it, which it does only for
// its owners; it says not, now, with `ERROR` 15. A node that says nothing says neither. The client
// keeps what it knows for each node it connects to, between runs, so that it offers to manage only
// the nodes it can.

/// What this client's node knows of being an owner of other nodes.
public struct Owned: Equatable, Sendable {
    /// For each node heard from, whether this client's node is one of its owners.
    public private(set) var nodes: [Address: Bool] = [:]

    public init() {}

    /// Whether this client's node is an owner of `node`: true or false as that node last said, nil
    /// if it has said nothing.
    public func isOwner(of node: Address) -> Bool? { nodes[node] }

    /// Takes what `node` said: this client's node is one of its owners, or not.
    public mutating func set(_ node: Address, owner: Bool) {
        nodes[node] = owner
    }

    /// Takes an `OWNER_CHANGED`, if it is about `me`, this client's node; one about another
    /// address says nothing of `me`. Returns whether it changed anything.
    @discardableResult
    public mutating func take(_ change: OwnerChange, me: Address?) -> Bool {
        guard let me, change.contact == me, change.owner <= 1 else { return false }
        let owner = change.owner == 1
        guard nodes[change.from] != owner else { return false }
        nodes[change.from] = owner
        return true
    }

    /// As kept between runs: each node's address in hex, and whether it is an owner of it.
    public var stored: [String: Bool] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.key.description, $0.value) })
    }

    /// Read back from `stored`. An entry whose key is not an address is passed over.
    public init(stored: [String: Bool]) {
        for (key, owner) in stored {
            if let a = Address(hex: key) { nodes[a] = owner }
        }
    }
}
