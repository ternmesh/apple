// The People tab: the contacts the node holds, the addresses it refused because they were not
// among them, and, beside them, who is near. Saving an address as a contact is what lets it in: the node takes it the
// next time it asks. A contact is added from the QR code on its owner's node screen, their link,
// the address, or their card, and shows the short code its owner can check against their own.

import SwiftUI
import TernKit

struct PeopleView: View {
    enum Half: Hashable { case contacts, nearby }

    @EnvironmentObject private var model: NodeModel
    @State private var half = Half.contacts
    /// The card of someone near the user is adding as a contact.
    @State private var addingCard: Card?
    @State private var adding = false
    @State private var renaming: Contact?
    @State private var name = ""
    @State private var saving: Asked?
    @State private var showing: Contact?
    /// A contact the user asked to remove, whose chat could go too: as it was shown when they asked.
    @State private var removing: ForgetRequest?
    /// A contact the user asked to make an owner of their node, until they confirm.
    @State private var owning: Contact?
    /// A contact whose node the user manages over the mesh.
    @State private var managing: Address?
    /// A contact whose node the user checks they are an owner of.
    @State private var checking: Address?

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section {
                    Picker("Show", selection: $half) {
                        Text("Contacts").tag(Half.contacts)
                        Text(nearCount > 0 ? "Nearby · \(nearCount)" : "Nearby").tag(Half.nearby)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if half == .nearby {
                    NearbySections(adding: $addingCard)
                } else {
                AskedSection(saving: $saving)
                SwiftUI.Section {
                    if model.records.contacts.isEmpty {
                        Text("No contacts yet. Add one with the button above, by scanning the code under My Address on their Node tab, or from their link.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sortedContacts(model.records), id: \.address) { c in
                        NavigationLink(value: Peer.contact(c.address)) {
                            ContactRow(contact: c)
                        }
                        .contextMenu {
                            Button("Rename") { rename(c) }
                            Button("Show Code") { showing = c }
                            ShareLink(item: Sharing.link(c.address))
                            Button("Copy Address") { copyToClipboard(Sharing.text(c.address)) }
                            if model.speaksManaging {
                                ManageMenuItems(
                                    address: c.address, manage: { managing = c.address }, check: {
                                        model.checkOwner(c.address)
                                        checking = c.address
                                    })
                                if c.isOwner {
                                    Button("Remove as Owner") { model.setOwner(c.address, false) }
                                } else if c.owner != nil {
                                    Button("Make Owner…") { owning = c }
                                }
                            }
                            Button("Remove", role: .destructive) { remove(c) }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { remove(c) }
                            Button("Rename") { rename(c) }
                        }
                    }
                }
                }
            }
            .navigationTitle("People")
            .nodeStatus()
            .navigationDestination(for: Peer.self) { peer in
                ChatView(peer: peer)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Contact", systemImage: "person.badge.plus")
                    }
                    .disabled(!model.isConnected)
                }
            }
            .sheet(isPresented: $adding) { AddContactSheet() }
            .sheet(item: $addingCard) { c in
                AddContactSheet(
                    text: Sharing.text(c.address), name: c.name,
                    nameNote: c.name.isEmpty ? nil : "Their card says “\(c.name)”. Save them under any name you like.")
                    .environmentObject(model)
            }
            .sheet(item: $showing) { c in
                CodeSheet(title: c.name.isEmpty ? c.address.short : c.name, address: c.address)
            }
            .savesAsked($saving)
            .makesOwner($owning)
            .navigationDestination(
                isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } })
            ) {
                if let managing { ManageView(node: model.managed(managing)) }
            }
            .navigationDestination(
                isPresented: Binding(get: { checking != nil }, set: { if !$0 { checking = nil } })
            ) {
                if let checking { OwnerCheckView(node: model.managed(checking)) }
            }
            // A client that offers to forget while it removes sends both, the forgetting first.
            .confirmationDialog(
                "Remove \(removing?.name ?? "")?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing
            ) { r in
                Button("Remove", role: .destructive) { if case let .contact(a) = r.peer { model.removeContact(a) } }
                Button("Remove and Delete Chat", role: .destructive) {
                    if case let .contact(a) = r.peer { model.forget(r.peer, through: r.through) { model.removeContact(a) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { r in
                Text("The node forgets the contact. Your chat with them is kept. Remove and Delete Chat also erases "
                    + "every message and invite in it from your node, and from every phone or computer connected to it. "
                    + "This can't be undone." + (r.unsent ? " " + Words.forgetUnsent : ""))
            }
            .alert(
                "Rename contact",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField("Name", text: $name)
                Button("Save") {
                    if let c = renaming { model.saveContact(c.address, name: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .showsProblems()
        }
    }

    /// How many are near: the cards the node holds, and the neighbours that sent none.
    private var nearCount: Int {
        let cards = model.speaksCards ? Set(model.records.cards.keys.map(model.records.routingId(of:))) : []
        return cards.count + model.records.neighbours.keys.filter { !cards.contains($0) }.count
    }

    /// Removes the contact, or, where its chat could go too, asks whether to delete it as well.
    private func remove(_ c: Contact) {
        let conversation = model.records.conversation(with: .contact(c.address))
        if model.canForget(conversation), let request = ForgetRequest(conversation) {
            removing = request
        } else {
            model.removeContact(c.address)
        }
    }

    private func rename(_ c: Contact) {
        name = c.name
        renaming = c
    }
}

struct ContactRow: View {
    let contact: Contact
    @EnvironmentObject private var model: NodeModel

    var body: some View {
        let name = contact.name.isEmpty ? contact.address.short : contact.name
        HStack(spacing: 12) {
            Avatar(name: name, key: contact.address.description)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                HStack(spacing: 6) {
                    Text(contact.session == 1 ? "Secure" : "Not talked yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if contact.isOwner { Tag("Owner") }
                }
            }
            Spacer()
            if let n = model.records.neighbours[model.records.routingId(of: contact.address)] {
                SignalBars(quarterDb: n.snrQuarterDb)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The addresses the node refused this run, each with a way to let it in. The list it is in shows
/// the alert that names the contact, with `savesAsked`: an alert inside a list's rows is not
/// reliably shown.
struct AskedSection: View {
    @EnvironmentObject private var model: NodeModel
    @Binding var saving: Asked?

    var body: some View {
        if !model.asked.isEmpty {
            SwiftUI.Section {
                ForEach(model.asked) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.address.short).font(.body.monospaced())
                        // The address in an ASKED is proved, and a card from it is signed by it: what
                        // the card says is still only what its sender says.
                        if let card = model.records.cards[a.address], let claim = Words.claim(card.name) {
                            Text(claim).font(.callout)
                        }
                        Text("\(Words.asked(a.why)), \(a.when.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            if model.records.contacts[a.address] == nil {
                                Button("Save as Contact") { saving = a }
                                    .disabled(!model.isConnected)
                            }
                            Button("Dismiss") { model.dismissAsked(a) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("Tried to reach you")
            } footer: {
                Text("Saving an address as a contact lets it in the next time it asks.")
            }
        }
    }
}

/// The alert that saves an address that asked as a contact, under the name typed.
struct SaveAskedAlert: ViewModifier {
    @EnvironmentObject private var model: NodeModel
    @Binding var saving: Asked?
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert(
            "Save as contact",
            isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } })
        ) {
            TextField("Name", text: $name)
            Button("Save") {
                if let a = saving { model.saveContact(a.address, name: name) }
                name = ""
            }
            Button("Cancel", role: .cancel) { name = "" }
        }
        .onChange(of: saving) { a in
            // A card from the address offers the name it carries, to keep or change.
            if let a, let card = model.records.cards[a.address] { name = card.name }
        }
    }
}

extension View {
    func savesAsked(_ saving: Binding<Asked?>) -> some View { modifier(SaveAskedAlert(saving: saving)) }
}

/// The addresses that asked, on a screen of their own.
struct AskedView: View {
    @State private var saving: Asked?

    var body: some View {
        List { AskedSection(saving: $saving) }
            .navigationTitle("Asked")
            .savesAsked($saving)
    }
}

/// A new contact: a link or an address, scanned, pasted or typed, or from a link the app was
/// opened with, and a name.
struct AddContactSheet: View {
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var name: String
    @State private var scanning = false
    /// Said under the name: where a name offered came from.
    private let nameNote: String?

    init(text: String = "", name: String = "", nameNote: String? = nil) {
        _text = State(initialValue: text)
        _name = State(initialValue: name)
        self.nameNote = nameNote
    }

    private var address: Address? { parseAddress(text) }

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Button {
                    scanning = true
                } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder")
                }
                #endif
                SwiftUI.Section {
                    TextField("Link or address", text: $text, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                } footer: {
                    if let address {
                        Text("Check with the owner that their node shows this short code: \(Sharing.shortCode(address))")
                    } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("That is not a Tern link or address.").foregroundStyle(.red)
                    }
                }
                TextField("Name", text: $name)
                if let nameNote {
                    Text(nameNote).font(.footnote).foregroundStyle(.secondary)
                }
                if name.utf8.count > Companion.nameMax {
                    Text("A name is at most \(Companion.nameMax) bytes.").foregroundStyle(.red)
                }
                // Opened from a link, the sheet may come before the node is connected.
                if !model.isConnected {
                    Text(Words.failure(.closed)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let address {
                            model.saveContact(address, name: name)
                            dismiss()
                        }
                    }
                    .disabled(address == nil || name.utf8.count > Companion.nameMax || !model.isConnected)
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanning) {
                NavigationStack {
                    ScannerView { found in
                        text = Sharing.read(found).map(Sharing.text) ?? found
                        scanning = false
                    }
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { scanning = false }
                        }
                    }
                }
            }
            #endif
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}
