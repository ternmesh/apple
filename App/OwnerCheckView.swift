// Whether the user's node is an owner of a contact's node: one `HELLO` over the mesh. An answer
// means it is, and the node can be managed from here; `ERROR` 15 means it is not; no answer says
// neither, and nothing is kept. Like a login: in, or not, and while it waits, the step it is at.

import SwiftUI
import TernKit

struct OwnerCheckView: View {
    @EnvironmentObject private var model: NodeModel
    @ObservedObject var node: ManagedNode
    /// The user is an owner, and went on to manage the node.
    @State private var managing = false

    var body: some View {
        if managing {
            ManageView(node: node)
        } else {
            check
        }
    }

    private var name: String { model.records.name(of: .contact(node.address)) }

    private var check: some View {
        Form {
            SwiftUI.Section {
                if node.working != nil {
                    ManageProgress(node: node)
                } else {
                    switch node.checked {
                    case .owner?:
                        Label(Words.anOwner(name), systemImage: "checkmark.circle")
                        Button("Manage Their Node") { managing = true }
                    case .notOwner?:
                        Label(Words.notAnOwner(name), systemImage: "xmark.circle")
                    case .noAnswer?:
                        Text(Words.noAnswer).foregroundStyle(.secondary)
                        Button("Try Again") { node.check() }.disabled(!model.isReady)
                    case let .failed(why)?:
                        Text(why).foregroundStyle(.secondary)
                        Button("Try Again") { node.check() }.disabled(!model.isReady)
                    case nil:
                        Button("Check") { node.check() }.disabled(!model.isReady)
                    }
                }
            } footer: {
                Text("Your node says hello to \(name) over the mesh. A node answers only its owners: if yours is "
                    + "not one, it says so, or says nothing.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Owner of \(name)?")
        .onAppear {
            if model.isReady && !node.isBusy { node.check() }
        }
    }
}

/// The request on its way to a managed node: what is asked, the step it is at, how long a node
/// that sleeps may take, and a way to stop waiting.
struct ManageProgress: View {
    @ObservedObject var node: ManagedNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                if let asking = node.asking {
                    Text(asking).font(.caption).foregroundStyle(.secondary)
                }
                if let working = node.working {
                    Text(working)
                }
                if let asleep = node.asleep {
                    Text(asleep).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        Button("Stop", role: .destructive) { node.cancel() }
            .buttonStyle(.borderless)
    }
}

/// What a contact's menu offers for managing their node: to manage it, if the user's node is one of
/// its owners; else to check, and, if it said not, that it is not theirs.
struct ManageMenuItems: View {
    @EnvironmentObject private var model: NodeModel
    let address: Address
    let manage: () -> Void
    let check: () -> Void

    var body: some View {
        switch model.isOwner(of: address) {
        case true?:
            Button("Manage Their Node…", action: manage)
        case false?:
            Text(Words.notYours)
            Button("Check If I'm an Owner", action: check)
        case nil:
            Button("Check If I'm an Owner", action: check)
        }
    }
}
