// Managing a node over the mesh, as one of its owners (companion version 17): its state as its last
// sync said, the settings an owner may change from afar (not its region or its PIN), its Bluetooth
// lock, its owners, and restarting it. Each request goes over the mesh and may take minutes; the
// screen says where it is. A setting changed is on trial until the node hears from the owner again,
// which the app sees to, and says so.

import SwiftUI
import TernKit

struct ManageView: View {
    @EnvironmentObject private var model: NodeModel
    @ObservedObject var node: ManagedNode
    @State private var power = 0
    @State private var confirmingLock = false
    @State private var confirmingRestart = false

    var body: some View {
        Form {
            status
            if node.trialEnds != nil || node.confirmed || node.settling { trial }
            if let me = node.records.me {
                about(me)
                settings(me)
                lock(me)
                owners
                restart
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Manage \(name)")
        .onDisappear { node.shown -= 1 }
        .onAppear {
            node.shown += 1
            if !node.synced && !node.isBusy { node.refresh() }
            power = Int(node.records.me?.power ?? 0)
        }
        .onChange(of: node.records.me?.power) { p in power = Int(p ?? 0) }
        .alert(
            "Could not do that",
            isPresented: Binding(get: { node.problem != nil }, set: { if !$0 { node.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(node.problem ?? "")
        }
    }

    private var name: String { model.records.name(of: .contact(node.address)) }

    /// Whether a request can be made now: one at a time, over a node that is connected.
    private var canAsk: Bool { model.isReady && !node.isBusy }

    // MARK: Sections

    private var status: some View {
        SwiftUI.Section {
            if node.working != nil {
                ManageProgress(node: node)
            } else if node.notOwner {
                Label(Words.notAnOwner(name), systemImage: "xmark.circle")
            } else if node.restarting {
                Text("The node is restarting. Ask for its state again in a minute.").foregroundStyle(.secondary)
            } else if !node.synced {
                Text("Not heard from yet.").foregroundStyle(.secondary)
            }
            Button(node.synced ? "Ask for Its State Again" : "Ask for Its State") { node.refresh() }
                .disabled(!canAsk)
        } footer: {
            Text("Your node carries each request over the mesh, one at a time. It may take a few minutes, and longer "
                + "for a node that sleeps. A node answers only its owners: if yours is not one, it says so, or says nothing.")
        }
    }

    @ViewBuilder
    private var trial: some View {
        SwiftUI.Section {
            if node.settling {
                Label(Words.restartSettle, systemImage: "arrow.clockwise").foregroundStyle(Color.warn)
            }
            if let ends = node.trialEnds {
                let minutes = max(1, Int(ends.timeIntervalSinceNow / 60 + 0.5))
                Label(Words.onTrial(minutes: minutes), systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(Color.warn)
                if !node.isBusy {
                    Button("Confirm Now") { node.confirm() }
                        .disabled(!model.isReady)
                }
            } else if node.confirmed {
                Label(Words.trialConfirmed, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        } header: {
            Text("Trial")
        }
    }

    /// What the node said of itself.
    @ViewBuilder
    private func about(_ me: NodeSelf) -> some View {
        SwiftUI.Section("This node") {
            LabeledContent("Role", value: Words.role(me.role))
            LabeledContent("Region", value: me.region.isEmpty ? "Not set" : me.region)
            LabeledContent("Transmit power", value: "\(me.power) dBm\(me.most == 1 ? ", the most it may" : "")")
            if let locked = me.locked {
                LabeledContent("Bluetooth", value: Words.locked(locked))
            }
            if let p = node.records.power, p.percent <= 100 {
                LabeledContent("Battery", value: "\(p.percent)%\(p.flags & 1 != 0 ? ", charging" : "")")
            }
            LabeledContent("Nearby nodes", value: node.records.neighbours.isEmpty ? "None heard" : "\(node.records.neighbours.count) heard")
            if let s = node.records.sleep {
                LabeledContent("Sleep", value: Words.sleep(s))
            }
            if let firmware = node.firmware {
                LabeledContent("Firmware", value: firmware)
            }
            if let v = node.nodeVersion {
                LabeledContent("Companion protocol", value: "version \(v)")
            }
            LabeledContent("Clock", value: me.time == 0 ? "Not set" : date(me.time).formatted(date: .abbreviated, time: .shortened))
        }
    }

    /// The settings an owner may change over the mesh: not the region, which would cut the node
    /// off, nor its PIN, which is for those beside it.
    @ViewBuilder
    private func settings(_ me: NodeSelf) -> some View {
        let v = node.agreed ?? 0
        SwiftUI.Section {
            Picker("Role", selection: Binding(get: { me.role }, set: { node.set(.role($0)) })) {
                Text("Leaf").tag(UInt8(0))
                Text("Relay").tag(UInt8(1))
            }
            Stepper("\(power) dBm", value: $power, in: -9...30)
                .monospacedDigit()
            if power != Int(me.power) {
                Button("Set Power to \(power) dBm") { node.set(.power(Int8(power))) }
            }
            if v >= 10 && me.most != 1 {
                Button("Send at the Most It May") { node.set(.power(Companion.powerMost)) }
            }
            if v >= 6, let cards = me.cards {
                Toggle("Show its card to nodes nearby", isOn: Binding(get: { cards == 1 }, set: { node.set(.cards($0 ? 1 : 0)) }))
            }
            if v >= 8, let f = node.records.fix, f.receiver != NodeFix.none {
                Toggle(
                    "Use its satellite receiver",
                    isOn: Binding(get: { f.receiver != NodeFix.off }, set: { node.set(.receiver($0 ? 1 : 0)) }))
            }
            if v >= 15, let s = node.records.sleep, me.role == 0 {
                Picker("Sleep", selection: Binding(get: { s.wake }, set: { node.set(.wake($0)) })) {
                    Text("Off").tag(UInt16(0))
                    if s.wake != 0 && !NodeView.wakes.contains(s.wake) {
                        Text(Words.duration(UInt32(s.wake))).tag(s.wake)
                    }
                    ForEach(NodeView.wakes, id: \.self) { Text("Every \(Words.duration(UInt32($0)))").tag($0) }
                }
            }
        } header: {
            Text("Settings")
        } footer: {
            Text("A setting changed over the mesh is on trial for \(Int(Companion.trial) / 60) minutes: if the node "
                + "does not hear from an owner again in that time, as it would not if the change cut it off, it goes "
                + "back to the old one. A new role or power restarts the node. Its region and its PIN can be changed "
                + "only at the node.")
        }
        .disabled(!canAsk)
    }

    @ViewBuilder
    private func lock(_ me: NodeSelf) -> some View {
        if let locked = me.locked {
            SwiftUI.Section {
                Toggle("Lock Bluetooth", isOn: Binding(
                    get: { locked == 1 },
                    set: { on in if on { confirmingLock = true } else { node.set(.lock(0)) } }))
                    .confirmationDialog("Lock the node's Bluetooth?", isPresented: $confirmingLock, titleVisibility: .visible) {
                        Button("Lock") { node.set(.lock(1)) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(Words.lockWarning)
                    }
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("For a node left where others can reach it, as on a mast: anyone who presses its button can pair "
                    + "with it, but while it is locked they cannot change it.")
            }
            .disabled(!canAsk)
        }
    }

    /// The node's contacts, each an owner or not.
    private var owners: some View {
        let contacts = node.records.contacts.values.sorted { label($0) < label($1) }
        return SwiftUI.Section {
            if contacts.isEmpty {
                Text("The node has no contacts.").foregroundStyle(.secondary)
            }
            ForEach(contacts, id: \.address) { c in
                if c.owner != nil {
                    Toggle(isOn: Binding(get: { c.isOwner }, set: { node.setOwner(c.address, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(c))
                            Text(Sharing.shortCode(c.address)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(label(c))
                }
            }
        } header: {
            Text("Owners")
        } footer: {
            Text("Owners can manage the node from anywhere on the mesh. It holds at most \(Companion.owners). Owners are "
                + "told when the owners change. If your node stops being an owner, you can no longer manage it from here.")
        }
        .disabled(!canAsk)
    }

    private var restart: some View {
        SwiftUI.Section {
            Button("Restart", role: .destructive) { confirmingRestart = true }
                .confirmationDialog("Restart \(name)?", isPresented: $confirmingRestart, titleVisibility: .visible) {
                    Button("Restart", role: .destructive) { node.restart() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The node restarts, and keeps its contacts, owners and settings. It is out of reach for a minute or so.")
                }
        }
        .disabled(!canAsk)
    }

    /// A contact of the managed node: this app's node, one of its contacts by the name saved here,
    /// or the name the managed node holds.
    private func label(_ c: Contact) -> String {
        if c.address == model.records.me?.address { return "Your node" }
        if let mine = model.records.contacts[c.address], !mine.name.isEmpty { return mine.name }
        return c.name.isEmpty ? c.address.short : c.name
    }
}

extension View {
    /// Asks before making `contact` one of the node's owners, and says what an owner can do.
    func makesOwner(_ contact: Binding<Contact?>) -> some View {
        modifier(OwnerDialog(contact: contact))
    }
}

private struct OwnerDialog: ViewModifier {
    @EnvironmentObject private var model: NodeModel
    @Binding var contact: Contact?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Make \(contact.map { $0.name.isEmpty ? $0.address.short : $0.name } ?? "") an owner of your node?",
            isPresented: Binding(get: { contact != nil }, set: { if !$0 { contact = nil } }),
            titleVisibility: .visible,
            presenting: contact
        ) { c in
            Button("Make Owner") { model.setOwner(c.address, true) }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(Words.ownerWarning(c.name.isEmpty ? c.address.short : c.name))
        }
    }
}
