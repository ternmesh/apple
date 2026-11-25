// Finding a node and connecting to it: a head card saying what stands in the way, Bluetooth's own
// states, or how the looking goes; the node the app is connected to or trying to be, the others it
// has used, and the nodes nearby. Disconnecting keeps a node;
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
            SwiftUI.Section {
                hero
            }

            if case .failed = model.linkState {
                SwiftUI.Section {
                    Text(words(model.linkState, turnedOff: model.turnedOff))
                        .foregroundStyle(Color.red)
                    Button("Try Again") { model.retry() }
                }
                .listRowBackground(Color.red.opacity(0.12))
            }

            if let id = model.remembered {
                SwiftUI.Section("This node") {
                    // Looking for other nodes while disconnected: what matters is that the app is off its own.
                    SettingRow(
                        title: model.nodeName ?? "Tern node", symbol: "antenna.radiowaves.left.and.right", tint: .heroTop,
                        subtitle: words(
                            model.disconnected && model.linkState == .scanning ? .disconnected : model.linkState,
                            turnedOff: model.turnedOff))
                    if let node = model.thisNode, node.label != nil {
                        LabeledContent("Bluetooth name", value: node.name)
                    }
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
                                SettingRow(
                                    title: node.shown, symbol: "antenna.radiowaves.left.and.right", tint: .heroTop,
                                    subtitle: model.found.contains(where: { $0.id == node.id }) ? "Nearby" : nil)
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
                ForEach(nearby) { node in
                    Button {
                        model.connect(to: node)
                    } label: {
                        SettingRow(
                            title: node.name, symbol: "waveform.path.ecg", tint: Color(hex: 0x0F766E),
                            value: "\(node.rssi) dBm")
                            .monospacedDigit()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if !nearby.isEmpty { Text("Other nodes nearby") }
            } footer: {
                Text("The first time, the system asks for a PIN: the one the node shows on its screen, or the one set on it. "
                    + "A node without a screen uses \(Companion.screenlessPasskey) until you set your own.")
            }
        }
        .navigationTitle("Connect")
        .onAppear { model.startScanning() }
        .onDisappear { model.stopScanning() }
        .confirmationDialog(
            "Forget \(forgetting?.shown ?? "this node")?",
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

    /// The nodes nearby the app has not used before.
    private var nearby: [FoundNode] { model.found.filter { f in !model.known.contains { $0.id == f.id } } }

    /// The head of the screen: what stands in the way of looking for nodes, Bluetooth missing, not
    /// allowed or off, or else how the looking goes.
    private var hero: some View {
        HeroCard(spacing: 16) {
            switch model.linkState {
            case .unsupported:
                heading("No Bluetooth", symbol: "exclamationmark.triangle", text: words(.unsupported))
            case .unauthorized:
                heading("Bluetooth not allowed", symbol: "lock", text: words(.unauthorized))
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) { HeroButton("Open Settings", symbol: "gear") }
                        .buttonStyle(.plain)
                }
                #endif
            case .poweredOff:
                heading("Bluetooth is off", symbol: "power", text: "Turn Bluetooth on to look for nodes.")
            case .starting:
                heading(words(.starting), symbol: "antenna.radiowaves.left.and.right", text: nil)
            default:
                heading(
                    words(.scanning), symbol: "waveform.path.ecg",
                    text: nearby.isEmpty ? "No other nodes found yet. Make sure yours is on and nearby."
                        : nearby.count == 1 ? "1 other node found nearby." : "\(nearby.count) other nodes found nearby.")
            }
        }
    }

    /// What the head card says: a symbol on a tile, a title, and why.
    private func heading(_ title: String, symbol: String, text: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let text { Text(text).font(.subheadline).opacity(0.85) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
