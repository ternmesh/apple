// The first time the app meets a node: the region it is in, without which it does not transmit at
// all; whether it relays; and the code to give others, with a first contact to add. A node the
// setup has been done for, but whose region has since been cleared, is asked for the region alone.

import SwiftUI
import TernKit

struct SetupView: View {
    private enum Step { case region, role, contact }

    @EnvironmentObject private var model: NodeModel
    @State private var at = 0
    @State private var adding = false
    /// Fixed when the setup opens: a node set up before is asked for its region only.
    @State private var steps: [Step] = []

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
                            Button("Skip") { model.finishSetup() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(at < steps.count - 1 ? "Next" : "Done") {
                            if at < steps.count - 1 { at += 1 } else { model.finishSetup() }
                        }
                        .disabled(step == .region && (model.records.me?.region.isEmpty ?? true))
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

    private func region(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            choice("EU868", detail: "Europe and the UK", selected: me.region == "EU868") { model.set(.region("EU868")) }
            choice("US915", detail: "The United States, Canada and Mexico", selected: me.region == "US915") {
                model.set(.region("US915"))
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
            choice("Leaf", detail: "Sends and receives its own messages only. Best for a node you carry.", selected: me.role == 0) {
                model.set(.role(0))
            }
            choice(
                "Relay", detail: "Also passes on messages for others. Best for a node left somewhere high, on power.",
                selected: me.role == 1
            ) { model.set(.role(1)) }
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
