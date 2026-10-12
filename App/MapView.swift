// The positions the node holds, on a map and in a list newest first, whom the node shares its own
// with, and where the node itself is, from its own satellite receiver or from a phone. A group member's position is under the group's name and the routing id the member
// claimed, never a contact's name: the id proves nothing about who sent it.

import SwiftUI
import TernKit

struct MapView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var focus: MapFocus?
    @State private var sharingWith: SharingTarget?

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if model.speaksPositions {
                    VStack(spacing: 0) {
                        PositionMap(points: own.map { [$0] + points } ?? points, showsPhone: model.locationAllowed, focus: focus)
                            .frame(minHeight: 220, maxHeight: .infinity)
                        Divider()
                        list
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    Text(model.agreed == nil
                        ? "Connect to a node to see positions here."
                        : "The node's firmware needs updating for positions.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $sharingWith) { target in
                ShareLocationView(peer: target.peer, current: model.sharing(with: target.peer))
                    .environmentObject(model)
            }
            .showsProblems()
        }
    }

    private var list: some View {
        List {
            if let f = model.ownFix {
                SwiftUI.Section("Your node") {
                    Button {
                        if let own { focus = MapFocus(id: own.id, count: (focus?.count ?? 0) + 1) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.nodeName ?? "Your node")
                            Text(PositionWords.receiver(f)).font(.caption).foregroundStyle(.secondary)
                            Text(own?.details ?? "No position yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.primary)
                    .disabled(own == nil)
                }
            }
            SwiftUI.Section("Positions") {
                if points.isEmpty {
                    Text("No one is sharing their location with you yet.").foregroundStyle(.secondary)
                }
                ForEach(points) { p in
                    Button {
                        focus = MapFocus(id: p.id, count: (focus?.count ?? 0) + 1)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(p.details).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.primary)
                }
            }
            if !sharing.isEmpty {
                SwiftUI.Section("You're sharing with") {
                    ForEach(sharing) { s in
                        Button {
                            sharingWith = SharingTarget(peer: s.peer)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.records.name(of: s.peer))
                                Text(PositionWords.sharing(s.sharing)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.primary)
                        .disabled(!model.isConnected)
                    }
                }
            }
        }
    }

    /// The node's own fix, if it has one, as an exact point.
    private var own: MapPoint? {
        guard let f = model.ownFix, f.has else { return nil }
        let p = Position(
            precision: Companion.precisionMax, lat: f.lat, lon: f.lon, altitude: f.altitude,
            accuracy: 0, age: f.age)
        return MapPoint(
            id: "self", name: model.nodeName ?? "Your node", position: p, isGroup: false, isOwn: true, ownAccuracy: f.accuracy)
    }

    /// Every position the node holds, newest first.
    private var points: [MapPoint] {
        let records = model.records
        let contacts = records.positions.map { address, p in
            MapPoint(
                id: "c:\(address)", name: records.name(of: .contact(address)),
                position: model.counted(p, key: "c:\(address)"), isGroup: false)
        }
        let members = records.groupPositions.map { member, p in
            MapPoint(
                id: "g:\(member.group):\(Words.routingId(member.from))",
                name: "\(records.name(of: .group(member.group))) · \(Words.routingId(member.from))",
                position: model.counted(p, key: "g:\(member.group):\(Words.routingId(member.from))"), isGroup: true)
        }
        return (contacts + members).sorted { ($0.position.age, $0.name) < ($1.position.age, $1.name) }
    }

    /// Whom the node shares with: contacts, then groups, each by name.
    private var sharing: [SharingRow] {
        let records = model.records
        let contacts = records.sharing.keys.compactMap { a in
            model.sharing(with: .contact(a)).map { SharingRow(peer: .contact(a), sharing: $0) }
        }
        let groups = records.groupSharing.keys.compactMap { g in
            model.sharing(with: .group(g)).map { SharingRow(peer: .group(g), sharing: $0) }
        }
        let byName: (SharingRow, SharingRow) -> Bool = {
            records.name(of: $0.peer).localizedCaseInsensitiveCompare(records.name(of: $1.peer)) == .orderedAscending
        }
        return contacts.sorted(by: byName) + groups.sorted(by: byName)
    }
}

/// A contact or group the node shares its position with, and how.
private struct SharingRow: Identifiable {
    var peer: Peer
    var sharing: PositionSharing
    var id: Peer { peer }
}

/// Whom the share sheet is open for, from the map.
struct SharingTarget: Identifiable {
    var peer: Peer
    var id: Peer { peer }
}
