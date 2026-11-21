// Who is near, beside the contacts on the People tab: the cards the node holds (draft/cards.md),
// the most recently heard first, then the neighbours it hears that sent no card. Each card is the
// name its sender claimed, in quotes; a neighbour is a contact's name when its routing id is one of
// theirs, else the id. A contact opens its conversation; a card from anyone else offers to add
// them as a contact, under a name the user chooses. Nothing is saved or sent but as the user asks.
// A neighbour that is no contact's and sent no card is only a routing id: it can be neither
// messaged nor added, which the list says under them, and tapping one says why.

import SwiftUI
import TernKit

/// The Nearby half of People, as sections of its list.
struct NearbySections: View {
    @EnvironmentObject private var model: NodeModel
    @Binding var adding: Card?
    /// The routing id of the heard-only node tapped, while its explanation shows.
    @State private var unknown: UInt32?

    var body: some View {
        let cards = model.speaksCards ? model.cardsHeard : []
        let carded = Set(cards.map { model.records.routingId(of: $0.address) })
        let neighbours = model.records.neighbours
        let bare = neighbours.values.filter { !carded.contains($0.routingId) }.sorted { $0.heard < $1.heard }

        if cards.isEmpty && bare.isEmpty {
            SwiftUI.Section {
                Text(model.agreed == nil
                    ? "Connect to a node to see who is near."
                    : "No one nearby yet. Other people's nodes show up here when your node hears them, and by name when they have their presence card on.")
                    .foregroundStyle(.secondary)
            }
        }
        if !cards.isEmpty {
            SwiftUI.Section {
                ForEach(cards) { c in row(c, heard: neighbours[model.records.routingId(of: c.address)]) }
            } header: {
                Text("Showing a card")
            } footer: {
                Text("A card's name is only what its sender says: anyone can put any name on one. Check the "
                    + "short code with them before you trust it. Yours is under My Address on the Node tab.")
            }
        }
        if !bare.isEmpty {
            SwiftUI.Section {
                ForEach(bare, id: \.routingId) { n in neighbourRow(n) }
            } header: {
                Text(cards.isEmpty ? "Heard by your node" : "Heard, no card")
            } footer: {
                // Why the ones that are only an id can't be messaged or added, and how to reach them.
                if bare.contains(where: { model.records.contact(routingId: $0.routingId) == nil }) {
                    Text(Words.heardOnly(cards: model.speaksCards, one: false))
                }
            }
            .alert(
                unknown.map(Words.routingId) ?? "",
                isPresented: Binding(get: { unknown != nil }, set: { if !$0 { unknown = nil } })
            ) {
                Button("OK", role: .cancel) { unknown = nil }
            } message: {
                Text(Words.heardOnly(cards: model.speaksCards, one: true))
            }
        }
    }

    /// A contact's card opens the conversation; anyone else's, the sheet that adds them.
    @ViewBuilder
    private func row(_ c: Card, heard: Neighbour?) -> some View {
        let contact = model.records.isContact(c.address) ? model.records.name(of: .contact(c.address)) : nil
        if contact != nil {
            NavigationLink(value: Peer.contact(c.address)) {
                CardRow(card: c, contact: contact, heard: heard)
            }
        } else {
            Button {
                adding = c
            } label: {
                CardRow(card: c, contact: nil, heard: heard)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.primary)
            .accessibilityHint("Adds them as a contact")
        }
    }

    @ViewBuilder
    private func neighbourRow(_ n: Neighbour) -> some View {
        let name = model.routingNames[n.routingId]
        let contact = model.records.contact(routingId: n.routingId)
        let row = HStack(spacing: 12) {
            Avatar(name: name ?? "", key: contact?.description ?? Words.routingId(n.routingId), unknown: name == nil, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if let name {
                        Text(name).fontWeight(.semibold)
                    } else {
                        // Only a routing id: muted, as a row there is nothing to do with.
                        Text(Words.routingId(n.routingId)).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                    if contact != nil { Tag("Contact", tint: .good) }
                }
                Text("\(Words.role(n.role)) · heard \(Words.ago(UInt32(n.heard)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SignalBars(quarterDb: n.snrQuarterDb)
        }
        if let contact {
            NavigationLink(value: Peer.contact(contact)) { row }
        } else {
            // Nothing to open: tapping says why, and how to reach its owner.
            Button {
                unknown = n.routingId
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.primary)
            .accessibilityHint("Explains why it can't be messaged or added")
        }
    }
}

/// One card: the name its sender claimed and how long ago it was heard, with how well when the
/// node hears it now. A contact's shows the name the user gave too, never in place of the card's.
struct CardRow: View {
    let card: Card
    /// What the user calls the card's sender, if they are a contact.
    let contact: String?
    var heard: Neighbour?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: card.name, key: card.address.description, unknown: card.name.isEmpty, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Words.cardName(card.name))
                        .fontWeight(.semibold)
                        .foregroundStyle(card.name.isEmpty ? Color.secondary : Color.primary)
                    if contact != nil { Tag("Contact", tint: .good) }
                }
                Text([heard.map { Words.role($0.role) }, "seen \(Words.ago(card.heard))", contact.map { "saved as \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let heard { SignalBars(quarterDb: heard.snrQuarterDb) }
            if contact == nil {
                Image(systemName: "person.badge.plus").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
