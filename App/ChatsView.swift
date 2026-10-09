// Every conversation, latest first, and starting a new one: with a contact, with an address
// pasted in, or in a new group.

import SwiftUI
import TernKit

struct ChatsView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var path: [Peer] = []
    @State private var newChat = false
    @State private var newGroup = false
    @State private var groupName = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !model.isConnected {
                    Text(words(model.linkState))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.disconnected {
                    Button("Connect") { model.retry() }
                }
                if !model.asked.isEmpty {
                    NavigationLink {
                        AskedView()
                    } label: {
                        Label(
                            model.asked.count == 1 ? "1 attempt to reach you was turned away" : "\(model.asked.count) attempts to reach you were turned away",
                            systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
                ForEach(model.conversations) { c in
                    NavigationLink(value: c.peer) {
                        ConversationRow(conversation: c)
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: Peer.self) { peer in
                ChatView(peer: peer)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New Chat") { newChat = true }
                        Button("New Group") {
                            groupName = ""
                            newGroup = true
                        }
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }
                    .disabled(!model.isConnected)
                }
            }
            .sheet(isPresented: $newChat) {
                NewChatSheet { peer in
                    newChat = false
                    path = [peer]
                }
            }
            .alert("New group", isPresented: $newGroup) {
                TextField("Name", text: $groupName)
                Button("Make") {
                    model.makeGroup(groupName) { group in path = [.group(group)] }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The node makes the group and its secret. Invite contacts to it from the group's chat.")
            }
            .showsProblems()
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: isGroup ? "person.3" : "person")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.name).font(.headline).lineLimit(1)
                    Spacer()
                    if let last = conversation.last, last.time != 0 {
                        Text(date(last.time), format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(conversation.last?.summary ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isGroup: Bool {
        if case .group = conversation.peer { return true }
        return false
    }
}

/// A time from the node's clock.
func date(_ time: UInt32) -> Date { Date(timeIntervalSince1970: TimeInterval(time)) }

/// Starts a conversation with a contact, or with an address pasted in.
struct NewChatSheet: View {
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var hex = ""
    let open: (Peer) -> Void

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("An address") {
                    TextField("64 hex digits", text: $hex, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    Button("Open Chat") {
                        if let address = parseAddress(hex) { open(.contact(address)) }
                    }
                    .disabled(parseAddress(hex) == nil)
                }
                SwiftUI.Section("A contact") {
                    ForEach(sortedContacts(model.records), id: \.address) { c in
                        Button(c.name.isEmpty ? c.address.short : c.name) { open(.contact(c.address)) }
                    }
                }
            }
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 360)
    }
}

/// An address typed or pasted: hex, with any spaces, colons or line breaks taken out.
func parseAddress(_ text: String) -> Address? {
    // A link or the text form, as draft/sharing.md writes them; pasted text brings a line break.
    if let address = Sharing.read(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return address }
    let digits = text.filter { $0.isHexDigit }
    guard digits.count == Address.length * 2,
          text.allSatisfy({ $0.isHexDigit || $0.isWhitespace || $0 == ":" })
    else { return nil }
    return Address(hex: String(digits))
}

func sortedContacts(_ records: Records) -> [Contact] {
    records.contacts.values.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
