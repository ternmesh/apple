// One conversation: its messages and invites oldest first, what the user sent and where it is,
// and the composer. What can be done with the contact or the group is in the toolbar, and a line
// under the title says when the node shares the user's location with them.

import SwiftUI
import TernKit

struct ChatView: View {
    let peer: Peer
    @EnvironmentObject private var model: NodeModel
    @State private var draft = ""
    @State private var naming = false
    @State private var name = ""
    @State private var inviting = false
    @State private var leaving = false
    @State private var ending = false
    @State private var sharingLocation = false
    @State private var showingCode = false

    private static let end = "end"

    var body: some View {
        let conversation = model.records.conversation(with: peer)
        let pending = model.outgoing.filter { $0.peer == peer }
        VStack(spacing: 0) {
            sharingLine
            sleepLine
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversation.items, id: \.id) { item in
                            ItemBubble(item: item)
                        }
                        ForEach(pending) { o in
                            OutgoingBubble(outgoing: o)
                        }
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
                .onChange(of: conversation.items.count + pending.count) { _ in
                    withAnimation { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .navigationTitle(conversation.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .onAppear { model.visible = peer }
        .onDisappear { if model.visible == peer { model.visible = nil } }
        .alert(title, isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $inviting) { inviteSheet }
        .sheet(isPresented: $showingCode) {
            if case let .group(g) = peer {
                JoinCodeSheet(group: g, name: model.records.groups[g]?.name ?? "").environmentObject(model)
            }
        }
        .sheet(isPresented: $sharingLocation) {
            ShareLocationView(peer: peer, current: model.sharing(with: peer))
                .environmentObject(model)
        }
        .confirmationDialog("Leave this group?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                if case let .group(g) = peer { model.leaveGroup(g) }
            }
        } message: {
            Text("The node forgets the group's secret. Its messages are kept, and the others are not told. To be in it again, you need an invite or its join code.")
        }
        .confirmationDialog("End the session?", isPresented: $ending, titleVisibility: .visible) {
            Button("End Session", role: .destructive) {
                if case let .contact(a) = peer { model.endSession(a) }
            }
        } message: {
            Text("Messages waiting for this address are not delivered. A new session starts with the next message either of you sends.")
        }
        .showsProblems()
    }

    // MARK: Location

    /// While the node shares the user's location with this contact or group: how, and for how
    /// long. Tapping it changes or stops it.
    @ViewBuilder
    private var sharingLine: some View {
        if model.speaksPositions, let s = model.sharing(with: peer) {
            Button {
                sharingLocation = true
            } label: {
                Label("Sharing your location · \(PositionWords.sharing(s))", systemImage: "location.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
        }
    }

    /// A contact that sleeps, as it told the node: messages to it wait with its relay until it
    /// next wakes, so one sent may stay sent a while.
    @ViewBuilder
    private var sleepLine: some View {
        if case let .contact(address) = peer, let wake = model.wake(of: address) {
            Label(Words.wakes(wake), systemImage: "moon.zzz")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.top, 4)
                .accessibilityHint("Messages to this contact wait until it wakes.")
        }
    }

    // MARK: Composer

    private var bytes: Int { Words.textBytes(draft) }

    private var canWrite: Bool {
        if case let .group(g) = peer { return model.records.groups[g] != nil }
        return true
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if canWrite {
                if canShareLocation {
                    Button { sharingLocation = true } label: {
                        Image(systemName: "location").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 6)
                    .disabled(!model.isConnected)
                    .accessibilityLabel("Share My Location")
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.theirs))
                    .onSubmit(send)
                if bytes > Companion.textMax - 28 {
                    Text("\(bytes)/\(Companion.textMax)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(bytes > Companion.textMax ? Color.red : Color.secondary)
                        .padding(.bottom, 6)
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.largeTitle)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
            } else {
                Text("You are not in this group.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
    }

    /// The node shares only with its contacts, and with a group only while it holds it.
    private var canShareLocation: Bool {
        guard model.speaksPositions else { return false }
        switch peer {
        case let .contact(a): return model.records.contacts[a] != nil
        case let .group(g): return model.records.groups[g] != nil
        }
    }

    private var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.canWrite && !text.isEmpty && Words.textBytes(text) <= Companion.textMax
    }

    private func send() {
        guard canSend else { return }
        if model.send(draft.trimmingCharacters(in: .whitespacesAndNewlines), to: peer) { draft = "" }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var menu: some View {
        switch peer {
        case let .contact(address):
            contactMenu(address, model.records.contacts[address])
        case let .group(group):
            groupMenu(group)
        }
    }

    private func contactMenu(_ address: Address, _ contact: Contact?) -> some View {
        Menu {
            Button(contact == nil ? "Save as Contact" : "Rename Contact") {
                name = contact?.name ?? ""
                naming = true
            }
            Button("Copy Address") { copyToClipboard(address.description) }
            // The node shares only with its contacts.
            if model.speaksPositions, contact != nil {
                Button("Share My Location…") { sharingLocation = true }
            }
            if (model.agreed ?? 0) >= 1 {
                Button("End Session", role: .destructive) { ending = true }
            }
            if let contact {
                Text(contact.session == 1 ? "Session: yes" : "Session: no")
            }
        } label: {
            Label("Contact", systemImage: "ellipsis.circle")
        }
        .disabled(!model.isConnected)
    }

    private func groupMenu(_ group: GroupID) -> some View {
        Menu {
            Button("Rename Group") {
                name = model.records.groups[group]?.name ?? ""
                naming = true
            }
            Button("Invite a Contact") { inviting = true }
                .disabled(model.records.contacts.isEmpty)
            if model.speaksJoinCodes {
                Button("Join Code…") { showingCode = true }
            }
            // Only while the node holds the group: a left group's conversation stays.
            if model.speaksPositions, model.records.groups[group] != nil {
                Button("Share My Location…") { sharingLocation = true }
            }
            Button("Leave Group", role: .destructive) { leaving = true }
        } label: {
            Label("Group", systemImage: "ellipsis.circle")
        }
        .disabled(!model.isConnected || model.records.groups[group] == nil)
    }

    private var title: String {
        switch peer {
        case .contact: "Contact's name"
        case .group: "Group's name"
        }
    }

    private func rename() {
        switch peer {
        case let .contact(address): model.saveContact(address, name: name)
        case let .group(group): model.nameGroup(group, name: name)
        }
    }

    private var inviteSheet: some View {
        NavigationStack {
            List(sortedContacts(model.records), id: \.address) { c in
                Button(c.name.isEmpty ? c.address.short : c.name) {
                    if case let .group(g) = peer { model.invite(c.address, to: g) }
                    inviting = false
                }
            }
            .navigationTitle("Invite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { inviting = false }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 320)
    }
}

/// A message, group message or invite, on the side of whoever wrote it.
struct ItemBubble: View {
    let item: Item
    @EnvironmentObject private var model: NodeModel

    var body: some View {
        HStack {
            if !item.isReceived { Spacer(minLength: 48) }
            VStack(alignment: item.isReceived ? .leading : .trailing, spacing: 3) {
                if let from {
                    let named = model.routingNames[from] != nil
                    Text(Words.sender(from, names: model.routingNames))
                        .font(named ? .caption.weight(.semibold) : .caption.monospaced())
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 4)
                        .help(Words.routingId(from))
                }
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(item.isReceived ? Color.theirs : Color.mine))
                    .foregroundStyle(item.isReceived ? Color.primary : Color.white)
                footer
            }
            if item.isReceived { Spacer(minLength: 48) }
        }
    }

    /// Who wrote a received group message: the routing id it claimed, not a proof. It shows as the
    /// contact whose id it is, if one is, and no more proved for that.
    private var from: UInt32? {
        guard case let .groupMessage(m) = item, item.isReceived else { return nil }
        return m.from
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case let .message(m):
            Text(m.text).textSelection(.enabled)
        case let .groupMessage(m):
            Text(m.text).textSelection(.enabled)
        case let .invite(i):
            VStack(alignment: .leading, spacing: 6) {
                Label(item.summary, systemImage: "person.3")
                if item.isReceived {
                    if model.records.groups[i.group] != nil {
                        Text("Joined").font(.caption)
                    } else {
                        Button("Join") { model.join(i.id) }
                            .buttonStyle(.bordered)
                            .disabled(!model.isConnected)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if item.time != 0 {
                Text(date(item.time), format: .dateTime.hour().minute())
            }
            if !item.isReceived {
                // A waiting one says what it waits for instead.
                Text(item.state == MessageState.waiting
                    ? Words.waiting(reason: item.reason, wait: item.wait) : Words.state(item.state))
            }
            // Sent to a contact that sleeps: its relay holds it until the contact wakes.
            if case let .message(m) = item, m.state == MessageState.sent, let wake = model.wake(of: m.contact) {
                Text("· " + Words.heldUntilWake(wake))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// A message the node has not yet said it holds.
struct OutgoingBubble: View {
    let outgoing: Outgoing
    @EnvironmentObject private var model: NodeModel

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                Text(outgoing.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.mine.opacity(0.55)))
                    .foregroundStyle(Color.white)
                switch outgoing.status {
                case .sending:
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                case .unanswered:
                    HStack {
                        Text("The node did not answer.").font(.caption2).foregroundStyle(.secondary)
                        Button("Retry") { model.resend(outgoing) }
                            .font(.caption)
                            .disabled(!model.canWrite)
                        Button("Discard", role: .destructive) { model.discard(outgoing) }
                            .font(.caption)
                    }
                case let .failed(why):
                    HStack {
                        Text(why).font(.caption2).foregroundStyle(.red)
                        Button("Discard", role: .destructive) { model.discard(outgoing) }
                            .font(.caption)
                    }
                }
            }
        }
    }
}
