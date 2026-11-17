// The node itself, as a dashboard: its name, link, battery and airtime at the head, then a row for
// each thing about it, each opening a screen of its own: its address to give others, the nodes it
// hears, its radio, what it shows of itself, its pairing PIN, and its firmware; and, last,
// switching to another node and turning it off. A setting changed here is shown once the node's
// SELF says so, not before.

import SwiftUI
import TernKit

struct NodeView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var power = 0
    @State private var passkey = ""
    /// The passkey typed when asked to choose one, apart from the one in Settings.
    @State private var ownPasskey = ""
    @State private var cardName = ""
    @State private var confirmingCards = false
    @State private var confirmingUpdate: FirmwareOffer?
    @State private var confirmingOff = false
    @State private var renaming = false
    @State private var label = ""
    /// The card of a neighbour the user is adding as a contact.
    @State private var adding: Card?
    /// Finding and connecting to another node, over the dashboard.
    @State private var switching = false

    /// The profiles a node is set to by name, each with where it is for. A node refuses one it does
    /// not have.
    static let regions: [(name: String, detail: String)] = [
        ("AU915", "Australia"),
        ("CL915", "Chile"),
        ("EU868", "Europe, the UK, Ukraine and South Africa"),
        ("KZ863", "Kazakhstan"),
        ("MY919", "Malaysia"),
        ("NZ915", "New Zealand"),
        ("RU868", "Russia"),
        ("TH920", "Thailand: the node raises its power to 17 dBm radiated if it is lower"),
        ("US915", "The United States, Canada, Mexico, Brazil, Argentina and Peru"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if model.records.me != nil && model.asksForPasskey && model.isConnected { choosePasskey }
                SwiftUI.Section {
                    hero
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                pages
                SwiftUI.Section {
                    Button {
                        switching = true
                    } label: {
                        SettingRow(title: "Switch Node", symbol: "arrow.left.arrow.right", tint: .gray)
                    }
                    .foregroundStyle(Color.primary)
                }
                turnOff
            }
            .formStyle(.grouped)
            .navigationTitle("Node")
            .sheet(isPresented: $switching) {
                ConnectView()
                    .environmentObject(model)
                    .frame(minWidth: 380, minHeight: 480)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rename") {
                        label = model.thisNode?.shown ?? ""
                        renaming = true
                    }
                    .disabled(model.thisNode == nil)
                }
            }
            .alert("Rename this node", isPresented: $renaming) {
                TextField("Name", text: $label)
                Button("Save") { if let id = model.remembered { model.rename(id, to: label) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only this device shows this name. It is not sent to your node, and no one else sees it. "
                    + "Leave it empty to use the Bluetooth name again.")
            }
            .onAppear {
                power = Int(model.records.me?.power ?? 0)
                cardName = model.records.me?.cardName ?? ""
            }
            .onChange(of: model.records.me?.power) { p in power = Int(p ?? 0) }
            .onChange(of: model.records.me?.cardName) { n in cardName = n ?? "" }
            .showsProblems()
        }
    }

    /// A typed passkey: exactly six digits, as the system asks for one when pairing.
    static func passkey(_ text: String) -> UInt32? {
        guard text.count == 6, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt32(text)
    }

    /// What `SELF`'s `pairing` says of how the node pairs.
    static func pairing(_ pairing: UInt8) -> String {
        switch pairing {
        case NodeSelf.pairingShown: "A new PIN on the node's screen"
        case NodeSelf.pairingDefault: "The default, \(Companion.screenlessPasskey)"
        case NodeSelf.pairingSet: "Your own PIN"
        default: "Unknown"
        }
    }

    // MARK: The dashboard

    /// The head of the dashboard: the node's name, what the link is doing, its battery and airtime
    /// as meters, and the two things done most often from here, giving its address and connecting.
    private var hero: some View {
        let on = Color.white
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.nodeName ?? "Tern node")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(model.isConnected ? Color(hex: 0x9FF0C6) : Color(hex: 0xFFD08A)).frame(width: 8, height: 8)
                    Text(heroLine).font(.footnote).opacity(0.85).lineLimit(1)
                }
            }
            if model.records.power != nil || model.records.airtime != nil {
                HStack(spacing: 10) {
                    gauge("Battery", value: batteryValue, fraction: batteryFraction, hint: batteryHint)
                    gauge("Airtime", value: airtimeValue, fraction: airtimeFraction, hint: airtimeHint)
                }
            }
            HStack(spacing: 10) {
                if let me = model.records.me {
                    NavigationLink {
                        page("My Address") { address(me) }
                    } label: {
                        heroButton("My Address", symbol: "qrcode")
                    }
                    .buttonStyle(.plain)
                }
                if model.disconnected || model.turnedOff {
                    Button { model.retry() } label: { heroButton("Connect", symbol: "link") }.buttonStyle(.plain)
                } else {
                    Button { model.disconnect() } label: { heroButton("Disconnect", symbol: "personalhotspot.slash") }
                        .buttonStyle(.plain)
                }
            }
        }
        .foregroundStyle(on)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [.heroTop, .heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private var heroLine: String {
        var parts = [model.isConnected ? "Connected" : words(model.linkState, turnedOff: model.turnedOff)]
        if let board = model.board, !board.isEmpty { parts.append(board) }
        if let me = model.records.me { parts.append(Words.role(me.role)) }
        return parts.joined(separator: " · ")
    }

    private func gauge(_ label: String, value: String, fraction: Double?, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).opacity(0.85)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    if let fraction { Capsule().fill(Color.white).frame(width: max(6, g.size.width * fraction)) }
                }
            }
            .frame(height: 6)
            if let hint { Text(hint).font(.caption2).opacity(0.85).lineLimit(2) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.13)))
    }

    private func heroButton(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.18)))
            .contentShape(Rectangle())
    }

    private var batteryValue: String {
        guard let p = model.records.power, p.percent <= 100 else { return "Unknown" }
        return "\(p.percent)%"
    }

    private var batteryFraction: Double? {
        guard let p = model.records.power, p.percent <= 100 else { return nil }
        return Double(p.percent) / 100
    }

    private var batteryHint: String? {
        guard let p = model.records.power else { return nil }
        if p.flags & 1 != 0 { return "Charging" }
        if p.flags & 2 != 0 { return "On external power" }
        return p.millivolts == 0 ? nil : volts(p.millivolts)
    }

    private var airtimeValue: String {
        guard let a = model.records.airtime else { return "Unknown" }
        if a.period == 0 { return "No limit" }
        return "\(min(100, Int(a.used) * 100 / Int(max(a.allowed, 1))))%"
    }

    private var airtimeFraction: Double? {
        guard let a = model.records.airtime, a.period != 0 else { return nil }
        return min(1, Double(a.used) / Double(max(a.allowed, 1)))
    }

    private var airtimeHint: String? {
        guard let a = model.records.airtime else { return nil }
        if a.wait > 0 { return "Next long frame in \(seconds(a.wait))" }
        if a.period == 0 { return "This region has no limit" }
        if a.used * 10 >= a.allowed * 9 { return "Nearly used up" }
        if a.used * 2 >= a.allowed { return "Over half used" }
        return "Plenty left to send"
    }

    /// A row for each screen the dashboard opens, with what it is set to now.
    @ViewBuilder
    private var pages: some View {
        SwiftUI.Section {
            NavigationLink {
                page("Nearby Nodes") { neighbours }
            } label: {
                SettingRow(
                    title: "Nearby Nodes", symbol: "waveform.path.ecg", tint: Color(hex: 0x0F766E),
                    value: model.records.neighbours.isEmpty ? "None heard" : "\(model.records.neighbours.count) heard")
            }
            if let me = model.records.me {
                NavigationLink {
                    page("Radio") { radio }
                } label: {
                    SettingRow(
                        title: "Radio", symbol: "dot.radiowaves.left.and.right", tint: Color(hex: 0x0B4F6C),
                        value: "\(me.region.isEmpty ? "Not set" : me.region) · \(Words.role(me.role))",
                        valueColor: me.region.isEmpty ? .red : .secondary)
                }
            }
            if hasPrivacy {
                NavigationLink {
                    page("Privacy & Location") {
                        if let me = model.records.me { card(me) }
                        receiver
                    }
                } label: {
                    SettingRow(
                        title: "Privacy & Location", symbol: "eye", tint: Color(hex: 0x7C3AED),
                        value: model.records.me?.cards.map { $0 == 1 ? "Card on" : "Card off" })
                }
            }
            if let me = model.records.me {
                NavigationLink {
                    page("Bluetooth PIN") { pin }
                } label: {
                    SettingRow(
                        title: "Bluetooth PIN", symbol: "lock", tint: Color(hex: 0xB45309),
                        value: me.pairing.map(Self.pairingShort),
                        valueColor: me.pairing == NodeSelf.pairingDefault ? .warn : .secondary)
                }
            }
        }
        if model.firmware != nil {
            SwiftUI.Section {
                NavigationLink {
                    page("Firmware") {
                        firmwareUpdate
                        software
                    }
                } label: {
                    SettingRow(
                        title: "Firmware", symbol: "cpu", tint: .gray,
                        value: updateReady ? "Update ready" : model.release.flatMap { $0.isEmpty ? nil : $0 },
                        valueColor: updateReady ? .accentColor : .secondary)
                }
            }
        }
    }

    /// A screen the dashboard opens: a form of its sections, with the same alerts as the dashboard.
    private func page(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .navigationTitle(title)
            .showsProblems()
    }

    private var hasPrivacy: Bool {
        (model.speaksCards && model.records.me?.cards != nil) || (model.ownFix.map { $0.receiver != NodeFix.none } ?? false)
    }

    private var updateReady: Bool {
        if case let .found(offer) = model.firmwareStatus { return offer.comparison == .newer }
        return false
    }

    /// How the node pairs, in a word or two, for its row.
    static func pairingShort(_ pairing: UInt8) -> String {
        switch pairing {
        case NodeSelf.pairingShown: "On its screen"
        case NodeSelf.pairingDefault: "Default"
        case NodeSelf.pairingSet: "Your own"
        default: "Unknown"
        }
    }

    // MARK: Sections

    /// Asks the user to choose a passkey for a node without a screen, which pairs with the default
    /// until they do. Once each connection, until they choose one or put it off.
    private var choosePasskey: some View {
        let key = Self.passkey(ownPasskey)
        return SwiftUI.Section {
            Text("This node has no screen, so it pairs with the default PIN, \(Companion.screenlessPasskey). "
                + "Until you choose your own, anyone nearby who knows the default can connect to it, read its "
                + "messages and change its settings.")
            TextField("New PIN, 6 digits", text: $ownPasskey)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            if key == Companion.screenlessPasskey {
                Text("Choose a PIN other than the default.").foregroundStyle(.red)
            }
            HStack {
                Button("Set PIN") {
                    if let key { model.setPasskey(key) }
                    ownPasskey = ""
                }
                .disabled(key == nil || key == Companion.screenlessPasskey)
                Spacer()
                Button("Not Now") {
                    ownPasskey = ""
                    model.putOffPasskey()
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Choose a PIN")
        } footer: {
            Text("Write it down: you type it the next time a device pairs with this node. You can change it later under Settings.")
        }
    }

    /// The node's address: its QR code to scan, the short code to read out, and the link to send.
    @ViewBuilder
    private func address(_ me: NodeSelf) -> some View {
        SwiftUI.Section {
            QRCodeView(address: me.address)
                .frame(maxWidth: .infinity)
        } footer: {
            Text("Someone with Tern scans the code to add you as a contact; a phone without it opens a page on "
                + "ternmesh.org that shows the address.")
        }
        SwiftUI.Section {
            Text(Sharing.shortCode(me.address))
                .font(.title.monospaced().weight(.semibold))
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            HStack {
                ShareLink(item: Sharing.link(me.address)) { Label("Share Link", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                Button { copyToClipboard(Sharing.text(me.address)) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text("Short code")
        } footer: {
            Text("Read this out to someone adding you: the code their phone shows should be the same.")
        }
        SwiftUI.Section("Full address") {
            Text(Sharing.grouped(me.address))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// Where the node is, which it transmits by; whether it passes on others' frames; and how loud.
    @ViewBuilder
    private var radio: some View {
        if let me = model.records.me {
            SwiftUI.Section {
                Picker("Region", selection: Binding(get: { me.region }, set: { model.set(.region($0)) })) {
                    if !Self.regions.contains(where: { $0.name == me.region }) {
                        Text(me.region.isEmpty ? "Not set" : me.region).tag(me.region)
                    }
                    ForEach(Self.regions, id: \.name) { Text($0.name).tag($0.name) }
                }
                // An image is for one region, and a new region restarts the node: not while one is on its way.
                .disabled(model.firmwareStatus.isTransferring)
                if let detail = Self.regions.first(where: { $0.name == me.region })?.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Region")
            } footer: {
                Text("Use the region you are in. It sets the frequencies your node uses and how long it may transmit.")
            }
            .disabled(!model.isConnected)

            SwiftUI.Section("Role") {
                roleChoice(
                    "Just me", tag: "Leaf", role: 0, current: me.role,
                    detail: "Sends and receives your own messages, and uses the least battery. Best for a node you carry.")
                roleChoice(
                    "Help the mesh", tag: "Relay", role: 1, current: me.role,
                    detail: "Also passes on other people's messages, so the mesh reaches further. Best for a node left on a hill, at a hut or in a window.")
            }
            .disabled(!model.isConnected)

            SwiftUI.Section {
                Stepper("\(power) dBm\(me.most == 1 && power == Int(me.power) ? ", the most it may" : "")", value: $power, in: -9...30)
                    .monospacedDigit()
                // A number the user sets is kept when the region changes, where the most moves with
                // it: so while the node sends at the most, even the number it sends at now is worth
                // setting.
                if power != Int(me.power) || me.most == 1 {
                    Button("Set Power to \(power) dBm") { model.set(.power(Int8(power))) }
                }
                // The most the node may transmit at, which it works out for its board, its antenna and
                // its region, and works out again when the region changes.
                if model.speaksMost && me.most != 1 {
                    Button("Send at the Most It May") { model.set(.power(Companion.powerMost)) }
                }
            } header: {
                Text("Transmit power")
            } footer: {
                Text("Your node may restart to apply a change. The app connects again on its own.")
            }
            .disabled(!model.isConnected)
        }
    }

    private func roleChoice(_ title: String, tag: String, role: UInt8, current: UInt8, detail: String) -> some View {
        Button {
            if role != current { model.set(.role(role)) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: role == current ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(role == current ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title).fontWeight(.semibold)
                        Tag(tag)
                    }
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(role == current ? .isSelected : [])
    }

    /// How the node pairs, and choosing another PIN.
    @ViewBuilder
    private var pin: some View {
        if let me = model.records.me {
            // How the node pairs, from a node of version 11 or later: before it, SELF does not say.
            if let pairing = me.pairing {
                SwiftUI.Section("Pairs with") {
                    Text(Self.pairing(pairing))
                        .foregroundStyle(pairing == NodeSelf.pairingDefault ? Color.warn : Color.primary)
                }
            }
            SwiftUI.Section {
                TextField("PIN, 6 digits", text: $passkey)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                HStack {
                    Button("Set PIN") {
                        if let key = Self.passkey(passkey) { model.setPasskey(key) }
                        passkey = ""
                    }
                    .disabled(Self.passkey(passkey) == nil)
                    Spacer()
                    // The node's default: a new passkey on its screen each time, or 123456 on a node
                    // without one. Nothing to go back to while it pairs with the default already.
                    Button("Use Default") { model.set(.passkey(Companion.passkeyDefault)) }
                        .disabled(me.pairing == NodeSelf.pairingShown || me.pairing == NodeSelf.pairingDefault)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Set a new PIN")
            } footer: {
                Text("A new PIN takes effect the next time a device pairs; this one stays paired. "
                    + "By default a node with a screen shows a new PIN each time, and one without a screen uses \(Companion.screenlessPasskey).")
            }
            .disabled(!model.isConnected)
        }
    }

    /// The node's presence card: off until the user turns it on, and the name it carries, which the
    /// node keeps while it is off. Neither is ever set but by the user, here.
    @ViewBuilder
    private func card(_ me: NodeSelf) -> some View {
        if model.speaksCards, let cards = me.cards {
            let name = cardName.trimmingCharacters(in: .whitespacesAndNewlines)
            SwiftUI.Section {
                Toggle(
                    "Send a presence card",
                    isOn: Binding(
                        get: { cards == 1 },
                        set: { on in if on { confirmingCards = true } else { model.set(.cards(0)) } }))
                    .confirmationDialog(
                        "Turn on the presence card?", isPresented: $confirmingCards, titleVisibility: .visible
                    ) {
                        Button("Turn On") { model.set(.cards(1)) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every couple of hours the node sends its address, in clear, and its card name to "
                            + "anyone near. They can tell it is the same node each time, and can use the address "
                            + "to reach you.")
                    }
                TextField("Card name", text: $cardName)
                if !Card.fits(name) {
                    Text("A card name is at most \(Companion.cardNameMax) bytes.").foregroundStyle(.red)
                }
                if name != (me.cardName ?? "") {
                    Button(name.isEmpty ? "Clear Card Name" : "Set Card Name") { model.setCardName(name) }
                        .disabled(!Card.fits(name))
                }
            } header: {
                Text("Presence card")
            } footer: {
                Text("Anyone near can see this node's address and the name above, every couple of hours, "
                    + "while the card is on. It is off until you turn it on. The cards of others show "
                    + "under People, Nearby, either way.")
            }
            .disabled(!model.isConnected)
        }
    }

    /// The node's satellite receiver, on or off, for a node that has one. Off saves its battery; it
    /// keeps its last fix, and a phone sharing its location gives it a newer one.
    @ViewBuilder
    private var receiver: some View {
        if let f = model.ownFix, f.receiver != NodeFix.none {
            SwiftUI.Section {
                Toggle(
                    "Use the node's satellite receiver",
                    isOn: Binding(get: { f.receiver != NodeFix.off }, set: { model.set(.receiver($0 ? 1 : 0)) }))
                Text(PositionWords.receiver(f)).foregroundStyle(.secondary)
            } header: {
                Text("GPS")
            } footer: {
                Text("On, the node works out where it is from satellites, on its own. Off saves its battery: "
                    + "it keeps the last position it had, and takes a newer one from your phone while you share "
                    + "your location.")
            }
            .disabled(!model.isConnected)
        }
    }

    /// Turning the node off, for a node of version 9 or later: only as the user asks, once told that
    /// nothing turns it on again but the node itself. Once it is off, what the app says of it, and
    /// connecting again once the user has turned it on.
    @ViewBuilder
    private var turnOff: some View {
        if model.turnedOff {
            SwiftUI.Section {
                Text(words(.disconnected, turnedOff: true))
                Button("Connect") { model.retry() }
            } header: {
                Text("Turned off")
            }
        } else if model.speaksOff {
            SwiftUI.Section {
                Button("Turn Off", role: .destructive) { confirmingOff = true }
                    .confirmationDialog(
                        "Turn off \(model.nodeName ?? "the node")?", isPresented: $confirmingOff,
                        titleVisibility: .visible
                    ) {
                        Button("Turn Off", role: .destructive) { model.turnOff() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The node stops sending and receiving, and this app cannot reach it. Only the node "
                            + "itself turns it on again, with its button, its reset or its power: nothing in Tern does.")
                    }
            } footer: {
                Text("Turning the node off saves its battery while it is put away. While it is off, it sends and "
                    + "receives nothing.")
            }
            .disabled(!model.isConnected)
        }
    }

    /// The nodes the node hears. Each is named, if it can be, by a contact's routing id, else by a
    /// card the node holds, as the claim it is, which offers to add them as a contact as People's Nearby
    /// does; one with neither stays a routing id.
    @ViewBuilder
    private var neighbours: some View {
        let list = model.records.neighbours.values.sorted { $0.heard < $1.heard }
        let cards = model.records.routingCards
        SwiftUI.Section {
            if list.isEmpty {
                Text("The node hears no other nodes yet.").foregroundStyle(.secondary)
            }
            ForEach(list, id: \.routingId) { n in
                // A contact's name, when the routing id is one of theirs.
                if let name = model.routingNames[n.routingId] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        Text(Words.routingId(n.routingId)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        heard(n)
                    }
                } else if let card = cards[n.routingId] {
                    Button {
                        adding = card
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Words.cardName(card.name))
                                    .foregroundStyle(card.name.isEmpty ? Color.secondary : Color.primary)
                                HStack {
                                    Text(Sharing.shortCode(card.address))
                                    Text(Words.routingId(n.routingId))
                                }
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                heard(n)
                            }
                            Spacer()
                            Image(systemName: "person.badge.plus").foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.primary)
                    .accessibilityHint("Adds them as a contact")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Words.routingId(n.routingId)).font(.body.monospaced())
                        Text("No card heard from this node.").font(.caption).foregroundStyle(.secondary)
                        heard(n)
                    }
                }
            }
        } footer: {
            Text("Bars show how clearly your node hears each one: four is strong, one is at the edge of range.")
        }
        .sheet(item: $adding) { c in
            AddContactSheet(
                text: Sharing.text(c.address), name: c.name,
                nameNote: c.name.isEmpty ? nil : "Their card says “\(c.name)”. Save them under any name you like.")
                .environmentObject(model)
        }
    }

    /// What a neighbour is, how well it is heard and how long ago.
    private func heard(_ n: Neighbour) -> some View {
        HStack(spacing: 8) {
            SignalBars(quarterDb: n.snrQuarterDb)
            Text("\(Words.role(n.role)) · \(Words.snr(n.snrQuarterDb)) · heard \(Words.duration(UInt32(n.heard))) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var software: some View {
        if let firmware = model.firmware {
            SwiftUI.Section("This node") {
                LabeledContent("Firmware", value: firmware)
                if let v = model.nodeVersion {
                    LabeledContent("Companion protocol", value: "version \(v)")
                }
                if let v = model.agreed {
                    LabeledContent("Spoken with this app", value: "version \(v)")
                }
                if let me = model.records.me {
                    LabeledContent("Clock", value: me.time == 0 ? "Not set" : date(me.time).formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    /// The node's release and board, and an update to the site's latest release.
    @ViewBuilder
    private var firmwareUpdate: some View {
        if model.firmware != nil {
            SwiftUI.Section {
                if let release = model.release {
                    LabeledContent("Release", value: release.isEmpty ? "None: built by hand" : release)
                }
                if let board = model.board, !board.isEmpty {
                    LabeledContent("Board", value: board)
                }
                if let board = model.board {
                    if board.isEmpty {
                        Text("This node can't be updated over Bluetooth. Flash it once over USB, and the app can update it from then on.")
                            .foregroundStyle(.secondary)
                        flashLink
                    } else if model.updateMethod == UpdateMethod.none {
                        // A board whose firmware, or bootloader, takes no image over Bluetooth.
                        Text(Words.updateOverUSB).foregroundStyle(.secondary)
                        flashLink
                    } else {
                        updateStatus
                    }
                } else {
                    Text("This node's firmware is too old to be updated from the app.")
                        .foregroundStyle(.secondary)
                    flashLink
                }
            } header: {
                Text("Firmware")
            }
        }
    }

    /// Asks before an update, on the button that offers it: a dialog attached to the dashboard is
    /// not shown over the Firmware page that the dashboard opens.
    private func confirmsUpdate(_ button: some View) -> some View {
        button.confirmationDialog(
            confirmingUpdate.map { "Update the node to \($0.release)?" } ?? "",
            isPresented: Binding(get: { confirmingUpdate != nil }, set: { if !$0 { confirmingUpdate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Update") { model.update() }
            Button("Not Now", role: .cancel) {}
        } message: {
            if confirmingUpdate?.image.update == .bootloader {
                Text("The node restarts into its bootloader, which takes the new firmware over Bluetooth. \(Words.bootloaderUpdateTakes) The node keeps its contacts, messages and settings.")
            } else {
                Text("It takes a few minutes. Keep the node near this device. If the link drops, the update goes on when the node is back. At the end the node restarts, and keeps its contacts, messages and settings.")
            }
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.firmwareStatus {
        case .idle:
            Button("Check for Update") { model.checkForUpdate() }
                .disabled(!model.isReady)
        case .checking:
            HStack {
                ProgressView()
                Text("Checking ternmesh.org…").foregroundStyle(.secondary)
            }
        case let .found(offer):
            switch offer.comparison {
            case .newer:
                LabeledContent("Available", value: offer.release)
                confirmsUpdate(
                    Button("Update to \(offer.release)…") { confirmingUpdate = offer }
                        .disabled(!model.isReady))
            case .unknown:
                Text("Release \(offer.release) is available. The node does not say which release it runs, so the app cannot tell whether it is newer.")
                    .foregroundStyle(.secondary)
                confirmsUpdate(
                    Button("Install \(offer.release)…") { confirmingUpdate = offer }
                        .disabled(!model.isReady))
            case .same:
                Text("Up to date: \(offer.release) is the latest release.").foregroundStyle(.secondary)
                Button("Check Again") { model.checkForUpdate() }
            case .older:
                Text("The node runs a newer release than the latest, \(offer.release).").foregroundStyle(.secondary)
                Button("Check Again") { model.checkForUpdate() }
            }
        case let .nothing(why):
            Text(why).foregroundStyle(.secondary)
            Button("Check Again") { model.checkForUpdate() }
        case let .downloading(offer):
            HStack {
                ProgressView()
                Text("Downloading \(offer.release)…").foregroundStyle(.secondary)
            }
            Button("Cancel", role: .destructive) { model.cancelUpdate() }
                .buttonStyle(.borderless)
        case let .sending(offer, held, size, waiting, canCancel):
            ProgressView(value: Double(held), total: Double(max(size, 1))) {
                Text("Sending \(offer.release)")
            } currentValueLabel: {
                Text(waiting ? "Waiting for the node to come back…" : "\(held * 100 / max(size, 1))%, \(kilobytes(held)) of \(kilobytes(size))")
            }
            if canCancel {
                Button("Cancel", role: .destructive) { model.cancelUpdate() }
                    .buttonStyle(.borderless)
            }
        case let .bootloader(offer, phase):
            if case let .transferring(.sending(sent, size)) = phase {
                ProgressView(value: Double(sent), total: Double(max(size, 1))) {
                    Text("Sending \(offer.release) to the bootloader")
                } currentValueLabel: {
                    Text("\(sent * 100 / max(size, 1))%, \(kilobytes(sent)) of \(kilobytes(size))")
                }
                Button("Stop", role: .destructive) { model.cancelUpdate() }
                    .buttonStyle(.borderless)
            } else {
                HStack {
                    ProgressView()
                    Text(Words.bootloader(phase)).foregroundStyle(.secondary)
                }
            }
            Text(Words.bootloaderUpdateTakes).font(.footnote).foregroundStyle(.secondary)
        case let .inBootloader(offer, why):
            Text(why).foregroundStyle(.secondary)
            // Not waiting for the node: it is in its bootloader, not connected as itself.
            Button("Update to \(offer.release) Again") { model.updateAgainInBootloader() }
        case let .restarting(offer, confirmed):
            HStack {
                ProgressView()
                Text(confirmed ? "The node is restarting into \(offer.release)…" : Words.update(.unconfirmed))
                    .foregroundStyle(.secondary)
            }
        case let .done(result):
            Text(result)
            Button("Check for Update") { model.checkForUpdate() }
                .disabled(!model.isReady)
        case let .failed(why):
            Text(why).foregroundStyle(.secondary)
            Button("Try Again") { model.checkForUpdate() }
                .disabled(!model.isReady)
        }
    }

    private var flashLink: some View {
        Link("Flash over USB at ternmesh.org/flash", destination: URL(string: "https://ternmesh.org/flash")!)
    }

    // MARK: Units

    private func kilobytes(_ bytes: Int) -> String {
        "\((bytes + 512) / 1024) KB"
    }

    private func volts(_ millivolts: UInt16) -> String {
        "\(millivolts / 1000).\(String(format: "%02d", Int(millivolts % 1000) / 10)) V"
    }

    private func seconds(_ milliseconds: UInt32) -> String {
        "\(milliseconds / 1000).\(milliseconds % 1000 / 100) s"
    }
}
