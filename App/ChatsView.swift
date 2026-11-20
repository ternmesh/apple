// Every conversation, latest first, with a search over their names and what was said in them; and
// starting a new one: with a contact, with an address pasted in, or in a new group. A conversation
// is deleted from here by swiping it, or from its context menu.

import SwiftUI
import TernKit

struct ChatsView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var newChat = false
    @State private var newGroup = false
    @State private var joining = false
    @State private var groupName = ""
    @State private var query = ""
    @State private var forgetting: ForgetRequest?

    /// The conversations with the search in their name or in anything said in them.
    private var shown: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.conversations }
        return model.conversations.filter { c in
            c.name.localizedCaseInsensitiveContains(q) || c.items.contains { $0.summary.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        // The model holds the path, so that a notification tapped can open a conversation.
        NavigationStack(path: $model.chatPath) {
            List {
                if !model.isConnected {
                    Text(words(model.linkState, turnedOff: model.turnedOff))
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
                if !query.isEmpty && shown.isEmpty {
                    Text("Nothing matches.").foregroundStyle(.secondary)
                }
                ForEach(shown) { c in
                    NavigationLink(value: c.peer) {
                        ConversationRow(conversation: c)
                    }
                    .contextMenu {
                        if model.canForget(c) {
                            Button(role: .destructive) { askToForget(c) } label: {
                                Label("Delete Chat", systemImage: "trash")
                            }
                        }
                    }
                    // Not by a full swipe: it asks first, and the row stays until the node forgets it.
                    .swipeActions(allowsFullSwipe: false) {
                        if model.canForget(c) {
                            Button(role: .destructive) { askToForget(c) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .nodeStatus()
            .searchable(text: $query, prompt: "Search messages")
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
                        if model.speaksJoinCodes {
                            Button("Join a Group…") { joining = true }
                        }
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }
                    .disabled(!model.isConnected)
                }
            }
            .sheet(isPresented: $joining) {
                JoinGroupSheet { group in model.chatPath = [.group(group)] }.environmentObject(model)
            }
            .sheet(isPresented: $newChat) {
                NewChatSheet { peer in
                    newChat = false
                    model.chatPath = [peer]
                }
            }
            .alert("New group", isPresented: $newGroup) {
                TextField("Name", text: $groupName)
                Button("Make") {
                    model.makeGroup(groupName) { group in model.chatPath = [.group(group)] }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The node makes the group and its secret. Invite contacts to it from the group's chat.")
            }
            .forgetsChat($forgetting)
            .showsProblems()
        }
    }

    /// Asks before deleting `conversation`, as it is shown now. The dialog comes up on the next turn
    /// of the main queue, once the swipe or the context menu has closed: SwiftUI's list crashed
    /// (a `UICollectionView` batch update it judged invalid) when a row's swipe was still closing as
    /// the dialog came and went and the node's `FORGOTTEN` took the row away.
    private func askToForget(_ conversation: Conversation) {
        guard let request = ForgetRequest(conversation) else { return }
        DispatchQueue.main.async { forgetting = request }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    @EnvironmentObject private var model: NodeModel

    var body: some View {
        let unread = conversation.unread > 0
        HStack(spacing: 12) {
            Avatar(name: conversation.name, key: avatarKey(conversation.peer), group: isGroup, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.name)
                        .font(.body.weight(unread ? .bold : .semibold))
                        .lineLimit(1)
                    if isGroup { Tag("Group") }
                    Spacer()
                    if let last = conversation.last, last.time != 0 {
                        Text(date(last.time), format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(unread ? Color.accentColor : Color.secondary)
                    }
                }
                HStack {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(unread ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Spacer()
                    if unread {
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
        .padding(.vertical, 3)
    }

    /// The last thing said, with who said it: "You:" for the user, and in a group the writer, by
    /// the contact whose routing id it claimed or by the id.
    private var preview: String {
        guard let last = conversation.last else { return "No messages yet" }
        if !last.isReceived { return "You: \(last.summary)" }
        if case let .groupMessage(m) = last { return "\(Words.sender(m.from, names: model.routingNames)): \(last.summary)" }
        return last.summary
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
