// The node itself: its address, its battery and airtime, the neighbours it hears, and its
// settings. A setting changed here is shown once the node's SELF says so, not before.

import SwiftUI
import TernKit

struct NodeView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var power = 0
    @State private var passkey = ""

    /// The profiles a node is set to by name. A node refuses one it does not have.
    private static let regions = ["US915", "EU868"]

    var body: some View {
        NavigationStack {
            Form {
                if let me = model.records.me {
                    identity(me)
                    battery
                    airtime
                    settings(me)
                    neighbours
                } else {
                    Text(model.isConnected ? "Waiting for the node…" : "Connect to a node to see it here.")
                        .foregroundStyle(.secondary)
                }
                software
            }
            .formStyle(.grouped)
            .navigationTitle(model.nodeName ?? "Node")
            .onAppear { power = Int(model.records.me?.power ?? 0) }
            .onChange(of: model.records.me?.power) { p in power = Int(p ?? 0) }
            .showsProblems()
        }
    }

    // MARK: Sections

    private func identity(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            Text(me.address.description)
                .font(.body.monospaced())
                .textSelection(.enabled)
            HStack {
                Button("Copy") { copyToClipboard(me.address.description) }
                ShareLink(item: me.address.description)
            }
            .buttonStyle(.borderless)
            LabeledContent("Role", value: Words.role(me.role))
            LabeledContent("Region", value: me.region.isEmpty ? "Not set" : me.region)
            LabeledContent("Power", value: "\(me.power) dBm")
            LabeledContent("Clock", value: me.time == 0 ? "Not set" : date(me.time).formatted(date: .abbreviated, time: .shortened))
        } header: {
            Text("Address")
        } footer: {
            Text("Give this to someone so they can write to you.")
        }
    }

    @ViewBuilder
    private var battery: some View {
        if let p = model.records.power {
            SwiftUI.Section("Battery") {
                LabeledContent("Charge", value: p.percent == 255 ? "Unknown" : "\(p.percent)%")
                LabeledContent("Voltage", value: p.millivolts == 0 ? "Unknown" : volts(p.millivolts))
                if p.flags & 1 != 0 { Text("Charging") }
                if p.flags & 2 != 0 { Text("On external power") }
            }
        }
    }

    @ViewBuilder
    private var airtime: some View {
        if let a = model.records.airtime {
            SwiftUI.Section("Airtime") {
                if a.period == 0 {
                    Text("This region has no limit on transmitting.")
                } else {
                    LabeledContent(
                        "Used",
                        value: "\(seconds(a.used)) of \(seconds(a.allowed)) per \(Words.duration(a.period))")
                    ProgressView(value: Double(min(a.used, a.allowed)), total: Double(max(a.allowed, 1)))
                    if a.wait > 0 {
                        LabeledContent("Next long frame", value: "in \(seconds(a.wait))")
                    }
                }
            }
        }
    }

    private func settings(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            Picker("Region", selection: Binding(get: { me.region }, set: { model.set(.region($0)) })) {
                if !Self.regions.contains(me.region) {
                    Text(me.region.isEmpty ? "Not set" : me.region).tag(me.region)
                }
                ForEach(Self.regions, id: \.self) { Text($0).tag($0) }
            }
            Picker("Role", selection: Binding(get: { me.role }, set: { model.set(.role($0)) })) {
                Text("Leaf").tag(UInt8(0))
                Text("Relay").tag(UInt8(1))
            }
            .pickerStyle(.segmented)
            Stepper("Power: \(power) dBm", value: $power, in: -9...30)
            if power != Int(me.power) {
                Button("Set Power to \(power) dBm") { model.set(.power(Int8(power))) }
            }
            TextField("Passkey, 6 digits", text: $passkey)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            HStack {
                Button("Set Passkey") {
                    if let key = UInt32(passkey) { model.set(.passkey(key)) }
                    passkey = ""
                }
                .disabled(UInt32(passkey).map { $0 > 999_999 } ?? true)
                Spacer()
                Button("Random Each Time") { model.set(.passkey(0xFFFF_FFFF)) }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Settings")
        } footer: {
            Text("The node may restart to apply a setting; the app connects again. A new passkey takes effect the next time a device pairs.")
        }
        .disabled(!model.isConnected)
    }

    @ViewBuilder
    private var neighbours: some View {
        let list = model.records.neighbours.values.sorted { $0.heard < $1.heard }
        SwiftUI.Section("Neighbours") {
            if list.isEmpty {
                Text("The node hears no other nodes yet.").foregroundStyle(.secondary)
            }
            ForEach(list, id: \.routingId) { n in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Words.routingId(n.routingId)).font(.body.monospaced())
                    Text("\(Words.role(n.role)), SNR \(Words.snr(n.snrQuarterDb)), heard \(Words.duration(UInt32(n.heard))) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var software: some View {
        if let firmware = model.firmware {
            SwiftUI.Section("Software") {
                LabeledContent("Firmware", value: firmware)
                if let v = model.nodeVersion {
                    LabeledContent("Companion protocol", value: "version \(v)")
                }
                if let v = model.agreed {
                    LabeledContent("Spoken with this app", value: "version \(v)")
                }
            }
        }
    }

    // MARK: Units

    private func volts(_ millivolts: UInt16) -> String {
        "\(millivolts / 1000).\(String(format: "%02d", Int(millivolts % 1000) / 10)) V"
    }

    private func seconds(_ milliseconds: UInt32) -> String {
        "\(milliseconds / 1000).\(milliseconds % 1000 / 100) s"
    }
}
