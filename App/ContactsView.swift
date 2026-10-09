// The contacts the node holds, the addresses it refused because they were not among them, and the
// way to who is about. Saving an address as a contact is what lets it in: the node takes it the
// next time it asks. A contact is added from the QR code on its owner's node screen, their link,
// the address, or their card, and shows the short code its owner can check against their own.

import SwiftUI
import TernKit

struct ContactsView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var adding = false
    @State private var renaming: Contact?
    @State private var name = ""
    @State private var saving: Asked?
    @State private var showing: Contact?

    var body: some View {
        NavigationStack {
            List {
                if model.speaksCards {
                    SwiftUI.Section {
                        NavigationLink(value: WhoIsAbout()) {
                            Label("Who's About", systemImage: "person.wave.2")
                        }
                        .badge(model.records.cards.count)
                    }
                }
                AskedSection(saving: $saving)
                SwiftUI.Section("Contacts") {
                    if model.records.contacts.isEmpty {
                        Text("No contacts yet.").foregroundStyle(.secondary)
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
                            Button("Remove", role: .destructive) { model.removeContact(c.address) }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { model.removeContact(c.address) }
                            Button("Rename") { rename(c) }
                        }
                    }
                }
            }
            .navigationTitle("Contacts")
            .navigationDestination(for: Peer.self) { peer in
                ChatView(peer: peer)
            }
            .navigationDestination(for: WhoIsAbout.self) { _ in
                WhoIsAboutView()
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
            .sheet(item: $showing) { c in
                CodeSheet(title: c.name.isEmpty ? c.address.short : c.name, address: c.address)
            }
            .savesAsked($saving)
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

    private func rename(_ c: Contact) {
        name = c.name
        renaming = c
    }
}

struct ContactRow: View {
    let contact: Contact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(contact.name.isEmpty ? contact.address.short : contact.name)
            HStack {
                Text(Sharing.shortCode(contact.address)).font(.caption.monospaced())
                Text(contact.session == 1 ? "Session: yes" : "Session: no").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
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
                        text = Sharing.text(found)
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
