// Who is about: the cards a node holds (draft/cards.md), as a person reads them. A card's name is
// a claim its sender made, so it is shown as one, beside the address's short code, and never as a
// contact's name. How long ago a card was heard is as of its record, and counts on from there.

import Foundation

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

    /// What to send for the node's own card, in order: the name `typed`, trimmed, if it is not
    /// the one `saved`, and then, if `turnOn` and the card is not `on`, cards on. Turning the card
    /// on takes the name typed with it, so it never goes out with an old one, and saving a name
    /// while the card is off turns it on: a name saved to a card left off was what confused people.
    public static func requests(on: Bool, saved: String, typed: String, turnOn: Bool) -> [Setting] {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [Setting] = []
        if name != saved { out.append(.cardName(name)) }
        if turnOn && !on { out.append(.cards(1)) }
        return out
    }
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

    /// Why a node heard with no card can be neither messaged nor added: all the node knows of it
    /// is a routing id, not its address. `one` for the node tapped, rather than those listed;
    /// `cards` whether the node speaks cards, without which waiting for one is no way to meet it.
    public static func heardOnly(cards: Bool, one: Bool) -> String {
        switch (one, cards) {
        case (false, true):
            return "Your node hears these, but they haven't shared a card, so all it knows is a short id, "
                + "not who they are. To talk to one, ask its owner for their link or QR code, or wait for "
                + "their card: nodes showing a card send one about every two hours."
        case (false, false):
            return "Your node hears these, but all it knows of each is a short id, not who they are. "
                + "To talk to one, ask its owner for their link or QR code."
        case (true, true):
            return "Your node hears this one, but it hasn't shared a card, so all your node knows is its "
                + "short id, not whose it is. You can't message or add it from here. To talk to it, ask "
                + "its owner for their link or QR code, or wait for its card: nodes showing a card send "
                + "one about every two hours."
        case (true, false):
            return "Your node hears this one, but all it knows is its short id, not whose it is. You can't "
                + "message or add it from here. To talk to it, ask its owner for their link or QR code."
        }
    }

    /// How long ago something was heard, `seconds` before now: "just now" under a minute, which
    /// is as fine as a list counting on every half minute can be, and otherwise "3 min ago".
    public static func ago(_ seconds: UInt32) -> String { seconds < 60 ? "just now" : "\(duration(seconds)) ago" }
}
