// The contacts the node holds, and the addresses it refused because they were not among them.
// Saving an address as a contact is what lets it in: the node takes it the next time it asks.

import SwiftUI
import TernKit

struct ContactsView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var adding = false
    @State private var renaming: Contact?
    @State private var name = ""
    @State private var saving: Asked?

    var body: some View {
        NavigationStack {
            List {
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
                            Button("Copy Address") { copyToClipboard(c.address.description) }
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
                Text(contact.address.short).font(.caption.monospaced())
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
                            Button("Save as Contact") { saving = a }
                            .disabled(!model.isConnected)
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

/// A new contact: an address, typed or pasted in hex, and a name.
struct AddContactSheet: View {
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var hex = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Address, 64 hex digits", text: $hex, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                TextField("Name", text: $name)
                if name.utf8.count > Companion.nameMax {
                    Text("A name is at most \(Companion.nameMax) bytes.").foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let address = parseAddress(hex) {
                            model.saveContact(address, name: name)
                            dismiss()
                        }
                    }
                    .disabled(parseAddress(hex) == nil || name.utf8.count > Companion.nameMax)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}
