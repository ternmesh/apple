// Sharing the node's position with a contact or a group: how exactly, with what, how often and
// for how long. The only place a SHARE or SHARE_GROUP is sent from, and only from its buttons: the
// choice to share, and how exactly, is the user's.

import SwiftUI
import TernKit

struct ShareLocationView: View {
    let peer: Peer
    @EnvironmentObject private var model: NodeModel
    @Environment(\.dismiss) private var dismiss
    @State private var precision: UInt8
    @State private var altitude: Bool
    @State private var accuracy: Bool
    @State private var interval: UInt16
    @State private var minutes: UInt16
    /// What the node already shares with `peer`, as the sheet opened.
    private let current: PositionSharing?

    /// - Parameter current: how the node shares with `peer` now, nil if it does not.
    init(peer: Peer, current: PositionSharing?) {
        self.peer = peer
        self.current = current
        let toGroup: Bool
        if case .group = peer { toGroup = true } else { toGroup = false }
        _precision = State(initialValue: current?.precision ?? 16)
        _altitude = State(initialValue: (current?.fields ?? 0) & PositionSharing.altitude != 0)
        _accuracy = State(initialValue: (current?.fields ?? 0) & PositionSharing.accuracy != 0)
        _interval = State(initialValue: current?.interval ?? (toGroup ? 900 : 300))
        // Sharing that ends keeps what it has left unless the user picks another duration, so a
        // change of precision alone does not change when it stops.
        _minutes = State(initialValue: current.map { $0.minutes == 0 ? UInt16(0) : Self.asNow } ?? 60)
    }

    /// The duration that keeps the minutes sharing has left, offered while it has some.
    private static let asNow = UInt16.max

    /// The five precisions the specification asks a client to offer, by what each covers.
    static let precisions: [UInt8] = [8, 12, 16, 20, 24]

    private var isGroup: Bool {
        if case .group = peer { return true }
        return false
    }

    /// At least `POSITION_MIN` for a contact and `POSITION_GROUP_MIN` for a group, in seconds.
    private var intervals: [UInt16] { isGroup ? [300, 900, 3600] : [60, 300, 900, 3600] }

    /// Altitude and accuracy say more of a coarse position than its cell does: only from a street.
    private var offersFields: Bool { precision >= 20 }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    Picker("How exactly", selection: $precision) {
                        ForEach(precisionChoices, id: \.self) { p in
                            Text(PositionWords.choice(p)).tag(p)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("How exactly")
                } footer: {
                    Text("Your node rounds your location to the size you pick before it leaves; the exact location stays between this phone and your node.")
                }
                if offersFields {
                    SwiftUI.Section {
                        Toggle("Include altitude", isOn: $altitude)
                        Toggle("Include accuracy", isOn: $accuracy)
                    }
                }
                SwiftUI.Section("How often, at most") {
                    Picker("How often, at most", selection: $interval) {
                        ForEach(intervalChoices, id: \.self) { s in
                            Text(Words.duration(UInt32(s))).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SwiftUI.Section("For how long") {
                    Picker("For how long", selection: $minutes) {
                        if let current, current.minutes != 0 {
                            Text("As now (\(PositionWords.left(current.minutes)))").tag(Self.asNow)
                        }
                        Text("1 hour").tag(UInt16(60))
                        Text("8 hours").tag(UInt16(480))
                        Text("Until I stop").tag(UInt16(0))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if current != nil {
                    SwiftUI.Section {
                        Button("Stop Sharing", role: .destructive) {
                            model.share(.off, with: peer)
                            dismiss()
                        }
                        .disabled(!model.isConnected)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share my location with \(model.records.name(of: peer))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(current == nil ? "Share" : "Update") {
                        model.share(chosen, with: peer)
                        dismiss()
                    }
                    .disabled(!model.isConnected || !model.speaksPositions)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
    }

    /// The five, and the precision shared now if it is another, so that it stays chosen.
    private var precisionChoices: [UInt8] {
        let p = current?.precision ?? 0
        return p == 0 || Self.precisions.contains(p) ? Self.precisions : (Self.precisions + [p]).sorted()
    }

    private var intervalChoices: [UInt16] {
        let s = current?.interval ?? 0
        return s == 0 || intervals.contains(s) ? intervals : (intervals + [s]).sorted()
    }

    /// The fields only with a precision that offers them; none below it.
    private var chosen: PositionSharing {
        var fields: UInt8 = 0
        if offersFields {
            if altitude { fields |= PositionSharing.altitude }
            if accuracy { fields |= PositionSharing.accuracy }
        }
        let minutes = self.minutes == Self.asNow ? current?.minutes ?? 60 : self.minutes
        return PositionSharing(precision: precision, fields: fields, interval: interval, minutes: minutes)
    }
}

/// A position's precision and sharing's time left, in words, the same on every screen.
enum PositionWords {
    /// How far a cell of `precision` is, north to south: the five the share sheet offers as the
    /// specification's table rounds them, and the rest from `360 / 2^precision` degrees.
    static func size(_ precision: UInt8) -> String {
        switch precision {
        case 8: return "about 150 km"
        case 12: return "about 10 km"
        case 16: return "about 600 m"
        case 20: return "about 40 m"
        case 24: return "a few metres"
        default:
            let metres = 360 / pow(2, Double(precision)) * 111_000
            if metres >= 1000 { return "about \(Int((metres / 1000).rounded())) km" }
            if metres >= 10 { return "about \(Int(metres.rounded())) m" }
            return "a few metres"
        }
    }

    /// What a list calls a precision: the five by name, the rest by size.
    static func word(_ precision: UInt8) -> String {
        switch precision {
        case 8: return "Region"
        case 12: return "Town"
        case 16: return "Neighbourhood"
        case 20: return "Street"
        case 24: return "Exact"
        default: return within(precision)
        }
    }

    /// How precise a position is: "Within about 10 km".
    static func within(_ precision: UInt8) -> String {
        precision == 24 || size(precision) == "a few metres" ? "Within a few metres" : "Within \(size(precision))"
    }

    /// A choice on the share sheet: "Town (about 10 km)".
    static func choice(_ precision: UInt8) -> String {
        switch precision {
        case 8, 12, 16, 20, 24: return "\(word(precision)) (\(size(precision)))"
        default: return within(precision)
        }
    }

    /// How long sharing has left: "45 min left", or "until you stop".
    static func left(_ minutes: UInt16) -> String {
        if minutes == 0 { return "until you stop" }
        if minutes < 120 { return "\(minutes) min left" }
        return "\((Int(minutes) + 30) / 60) h left"
    }

    /// Sharing in one line: "Neighbourhood · 45 min left".
    static func sharing(_ s: PositionSharing) -> String {
        "\(word(s.precision)) · \(left(s.minutes))"
    }
}
