// Who is about: the cards the node holds (draft/cards.md), the most recently heard first. Each is
// the name its sender claimed, in quotes, beside the short code of its address, with how long ago
// it was heard and whether it is a contact. A contact's card opens its conversation; anyone else's
// offers to add them as a contact, under a name the user chooses. Nothing is saved or sent to a
// card's address but as the user asks.

import SwiftUI
import TernKit

/// Where the Contacts screen goes for who is about.
struct WhoIsAbout: Hashable {}

struct WhoIsAboutView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var adding: Card?

    var body: some View {
        List {
            if model.speaksCards {
                let cards = model.cardsHeard
                SwiftUI.Section {
                    if cards.isEmpty {
                        Text("No cards heard yet.").foregroundStyle(.secondary)
                    }
                    ForEach(cards) { c in row(c) }
                } footer: {
                    Text("A card is a node's address and a name its owner chose, sent every couple of hours to "
                        + "anyone near while they have it turned on. Your node keeps the cards it heard in the last "
                        + "day. A card's name is only what its sender says: check the short code with them. Yours "
                        + "is on the Node screen.")
                }
            } else {
                Text(model.agreed == nil
                    ? "Connect to a node to see who is about."
                    : "The node's firmware needs updating for cards.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Who's About")
        .sheet(item: $adding) { c in
            AddContactSheet(
                text: Sharing.text(c.address), name: c.name,
                nameNote: c.name.isEmpty ? nil : "Their card says “\(c.name)”. Save them under any name you like.")
                .environmentObject(model)
        }
        .showsProblems()
    }

    /// A contact's card opens the conversation; anyone else's, the sheet that adds them.
    @ViewBuilder
    private func row(_ c: Card) -> some View {
        if model.records.isContact(c.address) {
            NavigationLink(value: Peer.contact(c.address)) {
                CardRow(card: c, contact: model.records.name(of: .contact(c.address)))
            }
        } else {
            Button {
                adding = c
            } label: {
                CardRow(card: c, contact: nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.primary)
            .accessibilityHint("Adds them as a contact")
        }
    }
}

/// One card: the name its sender claimed, the short code to check it by, and how long ago it was
/// heard. A contact's shows the name the user gave too, never in place of the card's.
struct CardRow: View {
    let card: Card
    /// What the user calls the card's sender, if they are a contact.
    let contact: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Words.cardName(card.name))
                    .foregroundStyle(card.name.isEmpty ? Color.secondary : Color.primary)
                HStack {
                    Text(Sharing.shortCode(card.address)).font(.caption.monospaced())
                    Text("Heard \(Words.ago(card.heard))").font(.caption)
                }
                .foregroundStyle(.secondary)
                if let contact {
                    Label("In your contacts as \(contact)", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if contact == nil {
                Image(systemName: "person.badge.plus").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
