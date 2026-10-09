// The positions the node holds, on a map and in a list newest first, and whom the node shares its
// own with. A group member's position is under the group's name and the routing id the member
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
                        PositionMap(points: points, showsPhone: model.locationAllowed, focus: focus)
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

    /// Every position the node holds, newest first.
    private var points: [MapPoint] {
        let records = model.records
        let contacts = records.positions.map { address, p in
            MapPoint(id: "c:\(address)", name: records.name(of: .contact(address)), position: p, isGroup: false)
        }
        let members = records.groupPositions.map { member, p in
            MapPoint(
                id: "g:\(member.group):\(Words.routingId(member.from))",
                name: "\(records.name(of: .group(member.group))) · \(Words.routingId(member.from))",
                position: p, isGroup: true)
        }
        return (contacts + members).sorted { ($0.position.age, $0.name) < ($1.position.age, $1.name) }
    }

    /// Whom the node shares with: contacts, then groups, each by name.
    private var sharing: [SharingRow] {
        let records = model.records
        let contacts = records.sharing.map { SharingRow(peer: .contact($0.key), sharing: $0.value) }
        let groups = records.groupSharing.map { SharingRow(peer: .group($0.key), sharing: $0.value) }
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
