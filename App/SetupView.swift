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
                if let me = model.records.me, let step {
                    head(step)
                    switch step {
                    case .region: region(me)
                    case .role: role(me)
                    case .contact: contact(me)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set Up")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // Where to go next, kept in reach under the steps rather than at the end of them.
            .safeAreaInset(edge: .bottom) {
                if let step { buttons(step) }
            }
            .sheet(isPresented: $adding) { AddContactSheet() }
            .showsProblems()
        }
        .onAppear { if steps.isEmpty { steps = model.setUp ? [.region] : [.region, .role, .contact] } }
        .interactiveDismissDisabled()
        .frame(minWidth: 380, minHeight: 480)
    }

    /// The step shown, nil until the steps are fixed.
    private var step: Step? { steps.isEmpty ? nil : steps[min(at, steps.count - 1)] }

    /// The head of a step: how far through the setup it is, what it asks, and why.
    private func head(_ step: Step) -> some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 0) {
                if steps.count > 1 {
                    let n = min(at, steps.count - 1) + 1
                    Text("Step \(n) of \(steps.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    ProgressView(value: Double(n), total: Double(steps.count))
                        .tint(Color.accentColor)
                        .padding(.top, 8)
                }
                Text(title(step))
                    .font(.title.weight(.bold))
                    .padding(.top, steps.count > 1 ? 16 : 0)
                Text(explained(step))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            .listRowBackground(Color.clear)
        }
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .region: "Where are you?"
        case .role: "Should your node help others?"
        case .contact: "Add someone to talk to"
        }
    }

    private func explained(_ step: Step) -> String {
        switch step {
        case .region:
            "Your node does not transmit until it knows which radio rules to follow. Only use a region "
                + "that is legal where you are. You can change it later on the Node screen."
        case .role: "A relay helps the mesh reach further but uses more battery. You can change this later."
        case .contact:
            "Your node only accepts messages from contacts. Have a friend scan your code, and scan theirs: "
                + "each of you adds the other."
        }
    }

    /// Skip, where a step may be skipped, and Next, or Done on the last.
    private func buttons(_ step: Step) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // The region cannot be skipped: until it is set the node sends nothing at all.
                if step != .region {
                    Button("Skip") { finish() }
                }
                Spacer()
                Button(at < steps.count - 1 ? "Next" : "Done") {
                    if at < steps.count - 1 { at += 1 } else { finish() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .region && chosenRegion.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
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
                ChoiceRow(title: choice.name, detail: choice.detail, selected: chosenRegion == choice.name) {
                    region = choice.name
                }
            }
        }
    }

    /// The two roles, as the Radio screen has them, with what each means for a node being set up.
    private func role(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            ChoiceRow(
                title: "Just me", tag: "Leaf", detail: "Sends and receives its own messages only. Best for a node you carry.",
                selected: (role ?? me.role) == 0
            ) { role = 0 }
            ChoiceRow(
                title: "Help the mesh", tag: "Relay",
                detail: "Also passes on messages for others. Best for a node left somewhere high, on power.",
                selected: (role ?? me.role) == 1
            ) { role = 1 }
        }
    }

    /// The node's address on the card My Address shows, with Add Contact beside Share Link.
    private func contact(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            AddressHero(name: model.nodeName ?? "Tern node", address: me.address) {
                ShareLink(item: Sharing.tappableLink(me.address)) { HeroButton("Share Link", symbol: "square.and.arrow.up") }
                    .buttonStyle(.plain)
                Button { adding = true } label: { HeroButton("Add Contact", symbol: "person.badge.plus") }
                    .buttonStyle(.plain)
            }
        } footer: {
            if !model.records.contacts.isEmpty {
                Text(model.records.contacts.count == 1 ? "You have 1 contact." : "You have \(model.records.contacts.count) contacts.")
            }
        }
    }
}
