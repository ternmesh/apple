// Who is about: the cards a node holds (draft/cards.md), as a person reads them. A card's name is
// a claim its sender made, so it is shown as one, beside the address's short code, and never as a
// contact's name. How long ago a card was heard is as of its record, and counts on from there.

/// A card is its address: the node holds one card for each.
extension Card: Identifiable {
    public var id: Address { address }
}

extension Card {
    /// The card `seconds` after its record came: heard that much longer ago. It stops at the
    /// largest `heard` can say rather than going round.
    public func later(by seconds: UInt32) -> Card {
        var c = self
        c.heard = heard.addingReportingOverflow(seconds).overflow ? .max : heard + seconds
        return c
    }

    /// Whether `name` may be the name a node's cards carry: at most `Companion.cardNameMax` bytes
    /// of UTF-8, as `SET` 6 takes it. Empty is no name.
    public static func fits(_ name: String) -> Bool { name.utf8.count <= Companion.cardNameMax }
}

extension Records {
    /// The cards held, the most recently heard first, each `since` its address's record came
    /// counted on (`Card.later(by:)`). Two heard as long ago are in the order of their names, and
    /// then of their addresses, so that the list does not reshuffle as it is drawn again.
    public func cardsHeard(since: (Address) -> UInt32 = { _ in 0 }) -> [Card] {
        cards.values.map { $0.later(by: since($0.address)) }.sorted {
            if $0.heard != $1.heard { return $0.heard < $1.heard }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.address.description < $1.address.description
        }
    }

    /// Whether the card from `address` is from one of the contacts: then its conversation is
    /// what it opens, not a new contact.
    public func isContact(_ address: Address) -> Bool { contacts[address] != nil }
}

extension Words {
    /// A card's name as a list shows it: in quotes, the sender's own words, or "No name".
    public static func cardName(_ name: String) -> String { name.isEmpty ? "No name" : "“\(name)”" }

    /// What the card from an address that asked says of its sender, or nil if it names no one.
    public static func claim(_ name: String) -> String? { name.isEmpty ? nil : "Says they are “\(name)”" }

    /// How long ago something was heard, `seconds` before now: "just now" under a minute, which
    /// is as fine as a list counting on every half minute can be, and otherwise "3 min ago".
    public static func ago(_ seconds: UInt32) -> String { seconds < 60 ? "just now" : "\(duration(seconds)) ago" }
}
