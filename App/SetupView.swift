// The first time the app meets a node: the region it is in, without which it does not transmit at
// all; whether it relays; and the code to give others, with a first contact to add. A node the
// setup has been done for, but whose region has since been cleared, is asked for the region alone.
//
// The region and the role are each a setting the node restarts to apply, which drops the
// connection: so they are held here as the user chooses, and sent together when the setup ends,
// for the node to apply with one restart rather than one in the middle of each step.

import SwiftUI
import TernKit

struct SetupView: View {
    private enum Step { case region, role, contact }

    @EnvironmentObject private var model: NodeModel
    @State private var at = 0
    @State private var adding = false
    /// Fixed when the setup opens: a node set up before is asked for its region only.
    @State private var steps: [Step] = []
    /// What the user chose, not yet sent: nil for what the node has already.
    @State private var region: String?
    @State private var role: UInt8?

    var body: some View {
        NavigationStack {
            Form {
                if let me = model.records.me, !steps.isEmpty {
                    switch steps[min(at, steps.count - 1)] {
                    case .region: region(me)
                    case .role: role(me)
                    case .contact: contact(me)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(steps.count > 1 ? "Set Up (\(min(at, steps.count - 1) + 1) of \(steps.count))" : "Set Up")
            .toolbar {
                if let step = steps.isEmpty ? nil : steps[min(at, steps.count - 1)] {
                    // The region cannot be skipped: until it is set the node sends nothing at all.
                    if step != .region {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Skip") { finish() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(at < steps.count - 1 ? "Next" : "Done") {
                            if at < steps.count - 1 { at += 1 } else { finish() }
                        }
                        .disabled(step == .region && chosenRegion.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $adding) { AddContactSheet() }
            .showsProblems()
        }
        .onAppear { if steps.isEmpty { steps = model.setUp ? [.region] : [.region, .role, .contact] } }
        .interactiveDismissDisabled()
        .frame(minWidth: 380, minHeight: 480)
    }

    /// The region as it will be once the setup ends: the one chosen, or the node's own.
    private var chosenRegion: String { region ?? model.records.me?.region ?? "" }

    /// Sends what was chosen, the region first, and ends the setup. Each is sent only if it is not
    /// what the node has already, so a setup that changes nothing restarts nothing.
    private func finish() {
        if let me = model.records.me {
            if let region, region != me.region { model.set(.region(region)) }
            if let role, role != me.role { model.set(.role(role)) }
        }
        model.finishSetup()
    }

    private func region(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            ForEach(NodeView.regions, id: \.name) { choice in
                self.choice(choice.name, detail: choice.detail, selected: chosenRegion == choice.name) {
                    region = choice.name
                }
            }
        } header: {
            Text("Where are you?")
        } footer: {
            Text("Your node does not transmit until it knows which radio rules to follow. Only use a region "
                + "that is legal where you are. You can change it later on the Node screen.")
        }
    }

    private func role(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            choice("Leaf", detail: "Sends and receives its own messages only. Best for a node you carry.", selected: (role ?? me.role) == 0) {
                role = 0
            }
            choice(
                "Relay", detail: "Also passes on messages for others. Best for a node left somewhere high, on power.",
                selected: (role ?? me.role) == 1
            ) { role = 1 }
        } header: {
            Text("Should your node help others?")
        } footer: {
            Text("A relay helps the mesh reach further but uses more battery. You can change this later.")
        }
    }

    private func contact(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            QRCodeView(address: me.address)
                .frame(maxWidth: .infinity)
            LabeledContent("Short code") {
                Text(Sharing.shortCode(me.address)).font(.body.monospaced())
            }
            Button("Add Contact") { adding = true }
            if !model.records.contacts.isEmpty {
                Text(model.records.contacts.count == 1 ? "You have 1 contact." : "You have \(model.records.contacts.count) contacts.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Add someone to talk to")
        } footer: {
            Text("Your node only accepts messages from contacts. Have a friend scan your code, and scan theirs: "
                + "each of you adds the other.")
        }
    }

    private func choice(_ title: String, detail: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
