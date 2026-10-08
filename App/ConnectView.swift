// Finding a node and connecting to it: Bluetooth's own states, the nodes nearby, and the one
// the app is connected to, or trying to be.

import SwiftUI
import TernKit
#if canImport(UIKit)
import UIKit
#endif

struct ConnectView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var forgetting = false

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        List {
            SwiftUI.Section("Status") {
                Text(words(model.linkState))
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
                    Button("Forget This Node", role: .destructive) { forgetting = true }
                }
            }

            SwiftUI.Section {
                if model.found.isEmpty {
                    Text(canScan ? "Looking for nodes nearby…" : "Turn Bluetooth on to look for nodes.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.found) { node in
                    Button {
                        model.connect(to: node)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(node.name)
                                if node.id == model.remembered {
                                    Text("This node").font(.caption).foregroundStyle(.secondary)
                                }
                            }
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
                Text("Nodes nearby")
            } footer: {
                Text("The first time, the system asks for a passkey: the one the node shows on its screen, or the one set on it.")
            }
        }
        .navigationTitle("Connect")
        .onAppear { model.startScanning() }
        .onDisappear { model.stopScanning() }
        .confirmationDialog("Forget this node?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.forget() }
        } message: {
            Text("The app disconnects and deletes what it kept of the node. Its messages stay on the node.")
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
