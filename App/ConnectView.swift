// Finding a node and connecting to it: Bluetooth's own states, the one the app is connected to
// or trying to be, the others it has used, and the nodes nearby. Disconnecting keeps a node;
// forgetting it deletes what the app kept of it.

import SwiftUI
import TernKit
#if canImport(UIKit)
import UIKit
#endif

struct ConnectView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var forgetting: KnownNode?

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        List {
            SwiftUI.Section("Status") {
                // Looking for other nodes while disconnected: what matters is that the app is off its own.
                Text(words(model.disconnected && model.linkState == .scanning ? .disconnected : model.linkState))
                    .foregroundStyle(isFailure ? Color.red : Color.primary)
                if case .failed = model.linkState {
                    Button("Try Again") { model.retry() }
                }
                #if os(iOS)
                if model.linkState == .unauthorized, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                }
                #endif
            }

            if let id = model.remembered {
                SwiftUI.Section("This node") {
                    LabeledContent("Name", value: model.nodeName ?? "Tern node")
                    if let firmware = model.firmware {
                        LabeledContent("Firmware", value: firmware)
                    }
                    Text(id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if model.disconnected {
                        Button("Connect") { model.retry() }
                    } else {
                        Button("Disconnect") { model.disconnect() }
                    }
                    Button("Forget This Node", role: .destructive) {
                        forgetting = KnownNode(id: id, name: model.nodeName ?? "Tern node", chosen: Date())
                    }
                }
            }

            let others = model.known.filter { $0.id != model.remembered }
            if !others.isEmpty {
                SwiftUI.Section("Your other nodes") {
                    ForEach(others) { node in
                        HStack {
                            Button {
                                model.connect(to: node.id, name: node.name)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(node.name)
                                    if model.found.contains(where: { $0.id == node.id }) {
                                        Text("Nearby").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) {
                                forgetting = node
                            } label: {
                                Label("Forget", systemImage: "trash").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            SwiftUI.Section {
                let nearby = model.found.filter { f in !model.known.contains { $0.id == f.id } }
                if nearby.isEmpty {
                    Text(canScan ? "Looking for nodes nearby…" : "Turn Bluetooth on to look for nodes.")
                        .foregroundStyle(.secondary)
                }
                ForEach(nearby) { node in
                    Button {
                        model.connect(to: node)
                    } label: {
                        HStack {
                            Text(node.name)
                            Spacer()
                            Text("\(node.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Other nodes nearby")
            } footer: {
                Text("The first time, the system asks for a passkey: the one the node shows on its screen, or the one set on it.")
            }
        }
        .navigationTitle("Connect")
        .onAppear { model.startScanning() }
        .onDisappear { model.stopScanning() }
        .confirmationDialog(
            "Forget \(forgetting?.name ?? "this node")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { node in
            Button("Forget", role: .destructive) { model.forget(node.id) }
        } message: { _ in
            Text("Tern disconnects and deletes the messages and contacts it saved from this node. "
                + "They stay on the node, and come back if you connect to it again.")
        }
    }

    private var isFailure: Bool {
        if case .failed = model.linkState { return true }
        return [.unsupported, .unauthorized, .poweredOff].contains(model.linkState)
    }

    private var canScan: Bool {
        ![.unsupported, .unauthorized, .poweredOff, .starting].contains(model.linkState)
    }
}
