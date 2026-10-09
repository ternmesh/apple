// The app's one model: the Bluetooth link to the node, the connection over it, and the records
// it leaves, kept on disk between runs. The screens read what it publishes and ask it to act;
// they never touch the connection themselves.

import Combine
import CoreLocation
import Foundation
import TernKit
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A message the user sent that the node has not yet said it holds. Once it answers `QUEUED`, the
/// message is a record like any other and this goes.
struct Outgoing: Identifiable, Equatable {
    enum Status: Equatable {
        case sending
        /// No answer: it may have been sent. Sending again with the same `ref` sends it once.
        case unanswered
        case failed(String)
    }

    var id: UInt32 { ref }
    var ref: UInt32
    var peer: Peer
    var text: String
    var status: Status
    /// The greatest id the app held when it was first sent: a message the node holds past it, to
    /// the same peer with the same text, is this one, and it went.
    var after: UInt32 = 0
}

/// A node the app has connected to and keeps records of.
struct KnownNode: Identifiable, Equatable {
    var id: UUID
    var name: String
    /// When the user last chose it.
    var chosen: Date
}

/// A release of the firmware, and the image in it for the node.
struct FirmwareOffer: Equatable {
    var release: String
    var image: FirmwareImage
    /// The release against the one the node runs.
    var comparison: ReleaseComparison
}

/// Where updating the node's firmware is.
enum FirmwareStatus: Equatable {
    /// Not looked for.
    case idle
    case checking
    /// The site's release, for the node's board and region.
    case found(FirmwareOffer)
    /// Nothing to offer, and why.
    case nothing(String)
    case downloading(FirmwareOffer)
    /// Sending it to the node: `held` of `size` bytes, as the node has said. `waiting` while the
    /// link is down; it goes on when it is back.
    case sending(FirmwareOffer, held: Int, size: Int, waiting: Bool, canCancel: Bool)
    /// Sent, and waiting for the node to come back and say what it runs. `confirmed` if it
    /// answered `UPDATE_END`, false if that answer never came.
    case restarting(FirmwareOffer, confirmed: Bool)
    /// How it ended, in words.
    case done(String)
    case failed(String)

    /// Downloading the image or sending it.
    var isTransferring: Bool {
        switch self {
        case .downloading, .sending: return true
        default: return false
        }
    }
}

/// Someone not in the contacts tried to reach the node, and was refused.
struct Asked: Identifiable, Equatable {
    var id: Address { address }
    var address: Address
    var why: UInt8
    var when: Date
}

@MainActor
final class NodeModel: ObservableObject {
    @Published private(set) var linkState: BluetoothLink.State = .starting {
        didSet {
            if linkState != .ready { syncedOnThisLink = false }
            feedPosition()
        }
    }
    @Published private(set) var found: [FoundNode] = []
    @Published private(set) var remembered: UUID?
    /// The user disconnected from the remembered node, and the app stays off it until they connect.
    @Published private(set) var disconnected = false
    /// Every node the app keeps records of, most recently chosen first.
    @Published private(set) var known: [KnownNode] = []
    @Published private(set) var nodeName: String?
    @Published private(set) var records = Records() {
        didSet { feedPosition() }
    }
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var outgoing: [Outgoing] = [] {
        didSet { keepOutgoing() }
    }
    @Published private(set) var asked: [Asked] = [] {
        didSet { keepAsked() }
    }
    @Published private(set) var firmware: String?
    /// The node's board and release, from an `INFO` of version 4 or later; nil before. An empty
    /// board is a node that cannot be updated over Bluetooth.
    @Published private(set) var board: String?
    @Published private(set) var release: String?
    @Published private(set) var firmwareStatus = FirmwareStatus.idle
    /// The release the node ran when it was last checked for an update: what the offer was weighed against.
    private var checkedAgainst: String?
    @Published private(set) var nodeVersion: UInt8?
    /// The version both ends speak, once the node has answered.
    @Published private(set) var agreed: UInt8? {
        didSet { feedPosition() }
    }
    /// A refusal or failure to show the user, once.
    @Published var problem: String?
    /// Something to tell the user that is not a failure, once.
    @Published var notice: String?
    /// The user has let the app have their location: the map shows it, and the node is given it.
    @Published private(set) var locationAllowed = false
    /// The first-run setup was finished, or skipped, for this node.
    @Published private(set) var setUp = true

    /// The conversation on screen, which is read as it arrives.
    var visible: Peer? {
        didSet { markRead() }
    }

    /// Whether the app is in front: notifications are only for when it is not.
    /// iOS may launch the app in the background to restore its Bluetooth link, with no scene
    /// becoming active: it starts as the application is, not as active.
    var isActive = NodeModel.launchedActive {
        didSet {
            if isActive {
                markRead()
                location.renew()
            } else {
                save()
            }
        }
    }

    private let link: BluetoothLink
    private var saveTask: Task<Void, Never>?
    /// The `through` of a `READ` not yet answered, so the same one is not sent twice.
    private var reading: UInt32?
    /// Conversations seen that the node has not yet been told of, each up to the greatest id it
    /// held when seen. One seen behind another's unread item waits here until that one is read.
    private var seen: [Peer: UInt32] = [:]
    /// The greatest id the node has answered a send with. Its record may not have come yet, so a
    /// send made now matches only records past it: one the node queues for it is given a greater id.
    private var queuedFloor: UInt32 = 0
    /// The update under way, for the node `updateNode`, and the image it sends: kept once
    /// downloaded, so that an update cancelled or failed goes on without downloading again.
    private var updater: Updater?
    private var updateOffer: FirmwareOffer?
    private var updateNode: UUID?
    private var downloaded: (image: FirmwareImage, bytes: [UInt8])?
    private var firmwareTask: Task<Void, Never>?
    private let location = LocationFeed()
    /// The node has synced over the link that is up: the sharing the records hold is the node's
    /// now, not what it was before the link dropped. The link is ready a moment before its sync's
    /// records are taken, and sharing that ended meanwhile must not be fed a position.
    private var syncedOnThisLink = false {
        didSet { feedPosition() }
    }
    /// When the node was last given the phone's position, while the feed runs.
    private var positionSent: Date?
    /// The user turned sharing on and was asked for their location: what they answer may need saying.
    private var askedForLocation = false
    private static let nameKey = "org.ternmesh.tern.nodeName"
    private static let knownKey = "org.ternmesh.tern.known"
    /// The user was told the node shares only its own fix without the phone's location.
    private static let toldNoLocationKey = "org.ternmesh.tern.toldNoLocation"
    private static func setupKey(_ id: UUID) -> String { "org.ternmesh.tern.setup.\(id.uuidString)" }

    init() {
        link = BluetoothLink()
        remembered = link.remembered
        disconnected = link.isDisconnected
        nodeName = UserDefaults.standard.string(forKey: Self.nameKey)
        known = Self.loadKnown()
        // A node chosen before the app kept a list of them.
        if let id = remembered, !known.contains(where: { $0.id == id }) {
            known.insert(KnownNode(id: id, name: nodeName ?? "Tern node", chosen: Date()), at: 0)
            keepKnown()
        }
        if let id = link.remembered {
            records = Self.load(id)
            outgoing = Self.loadOutgoing(id)
            asked = Self.loadAsked(id)
        }
        conversations = records.conversations
        link.makeConnection = { [weak self] id in
            // The records already loaded are the node's, unless the link is opening to another.
            let held = (self?.remembered == id ? self?.records : nil) ?? Self.load(id)
            return Connection(
                records: held, now: BluetoothLink.clock, wallTime: { UInt32(Date().timeIntervalSince1970) })
        }
        link.onState = { [weak self] state in self?.linkState = state }
        link.onFound = { [weak self] found in self?.found = found }
        link.onEvent = { [weak self] event in self?.handle(event) }
        linkState = link.state
        location.onFix = { [weak self] fix in self?.give(fix) }
        location.onAuthorization = { [weak self] in self?.locationAuthorizationChanged() }
        locationAllowed = location.isAllowed
        ticking = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] now in
            guard let self, !self.heard.isEmpty else { return }
            self.clock = now
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Connecting

    func startScanning() { link.startScanning() }
    func stopScanning() { link.stopScanning() }

    func connect(to node: FoundNode) { connect(to: node.id, name: node.name) }

    /// Makes the node `id` the app's node and connects to it. The records of the node before it
    /// stay on disk, for when it is chosen again.
    func connect(to id: UUID, name: String) {
        if remembered != id {
            save()
            // The node first: what is set below is kept on disk under it.
            remembered = id
            records = Self.load(id)
            conversations = records.conversations
            showUnread()
            outgoing = Self.loadOutgoing(id)
            asked = Self.loadAsked(id)
            seen = [:]
            queuedFloor = 0
            firmware = nil
            nodeVersion = nil
            agreed = nil
            resetFirmware()
        }
        remembered = id
        nodeName = name
        UserDefaults.standard.set(name, forKey: Self.nameKey)
        known.removeAll { $0.id == id }
        known.insert(KnownNode(id: id, name: name, chosen: Date()), at: 0)
        keepKnown()
        link.connect(to: id)
        disconnected = link.isDisconnected
    }

    /// Tries again after a failure, or connects again after the user disconnected.
    func retry() {
        link.retry()
        disconnected = link.isDisconnected
    }

    /// Drops the link and stays off the node until the user connects again. The node and what the
    /// app kept of it stay: connecting again syncs only what is new.
    func disconnect() {
        link.disconnect()
        disconnected = link.isDisconnected
        save()
    }

    /// Forgets the node `id`, and deletes what the app kept of it. Its messages stay on the node.
    func forget(_ id: UUID) {
        known.removeAll { $0.id == id }
        keepKnown()
        guard id == remembered else { return Self.remove(id) }
        // The node goes first: closing the link settles sends in flight, and with no node they
        // are not written back under it.
        remembered = nil
        link.forget()
        disconnected = link.isDisconnected
        Self.remove(id)
        nodeName = nil
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        records = Records()
        conversations = []
        showUnread()
        outgoing = []
        asked = []
        seen = [:]
        queuedFloor = 0
        firmware = nil
        nodeVersion = nil
        agreed = nil
        resetFirmware()
    }

    var isConnected: Bool { linkState == .ready || linkState == .syncing }

    /// Connected, and the first sync done: what the app holds is the node's.
    var isReady: Bool { linkState == .ready }

    /// Unread messages across every conversation.
    var unread: Int { conversations.reduce(0) { $0 + $1.unread } }

    /// Whether to walk the user through the node's setup: the first time the app meets it once it
    /// has synced, and whenever its region is not set, without which it transmits nothing.
    var needsSetup: Bool {
        guard linkState == .ready, let me = records.me else { return false }
        return !setUp || me.region.isEmpty
    }

    /// The setup is over for the app's node: it is not offered for it again.
    func finishSetup() {
        guard let id = remembered else { return }
        UserDefaults.standard.set(true, forKey: Self.setupKey(id))
        setUp = true
    }

    /// Whether the setup is over for the node `id`. A node met before the setup existed, already
    /// given a region and a contact, counts as set up rather than being walked through it again.
    private func isSetUp(_ id: UUID, _ records: Records) -> Bool {
        if UserDefaults.standard.bool(forKey: Self.setupKey(id)) { return true }
        let done = !(records.me?.region.isEmpty ?? true) && !records.contacts.isEmpty
        if done { UserDefaults.standard.set(true, forKey: Self.setupKey(id)) }
        return done
    }

    /// The unread count on the app's icon.
    private func showUnread() {
        #if os(iOS)
        if #available(iOS 17, *) {
            UNUserNotificationCenter.current().setBadgeCount(unread)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = unread
        }
        #else
        NSApplication.shared.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
        #endif
    }

    /// Whether a message may be written now. Not while the first sync is under way: what the app
    /// holds is not yet the node's, and the `after` a send is matched from must be.
    var canWrite: Bool { linkState == .ready }

    // MARK: Messages

    /// Sends `text` to the conversation `peer`, under a new `ref`.
    /// Returns whether it was taken: one the same as a send still in flight is not, and stays with
    /// the writer.
    @discardableResult
    func send(_ text: String, to peer: Peer) -> Bool {
        guard canWrite else { return false }
        // The same text to the same peer while one is unresolved is that one again, under its ref:
        // two the node could not tell apart would leave a sync unable to say which of them went.
        if let o = outgoing.first(where: { $0.peer == peer && $0.text == text }) {
            guard o.status != .sending else {
                problem = "Still sending the same message. Send it again once the node answers."
                return false
            }
            resend(o)
            return true
        }
        let ref = UInt32.random(in: 1...UInt32.max)
        outgoing.append(Outgoing(
            ref: ref, peer: peer, text: text, status: .sending, after: max(records.greatest, queuedFloor)))
        transmit(ref)
        return true
    }

    /// Sends again what got no answer, with the same `ref`: the node sends it once whatever became
    /// of the first try.
    func resend(_ o: Outgoing) {
        guard canWrite, let i = outgoing.firstIndex(where: { $0.ref == o.ref }) else { return }
        // The node holds it: it went, and the ref may since have left the node's memory.
        if records.holdsSent(o.text, to: o.peer, after: o.after) { return discard(o) }
        outgoing[i].status = .sending
        transmit(o.ref)
    }

    func discard(_ o: Outgoing) {
        outgoing.removeAll { $0.ref == o.ref }
    }

    private func transmit(_ ref: UInt32) {
        guard let o = outgoing.first(where: { $0.ref == ref }) else { return }
        guard let c = link.connection else { return settle(ref, .failure(.closed)) }
        let then: (Result<Body, RequestFailure>) -> Void = { [weak self] result in self?.settle(ref, result) }
        switch o.peer {
        case let .contact(address): c.sendMessage(o.text, to: address, ref: ref, then: then)
        case let .group(group): c.sendToGroup(o.text, group: group, ref: ref, then: then)
        }
    }

    private func settle(_ ref: UInt32, _ result: Result<Body, RequestFailure>) {
        guard let i = outgoing.firstIndex(where: { $0.ref == ref }) else { return }
        switch result {
        case let .success(answer):
            if case let .queued(id) = answer { queuedFloor = max(queuedFloor, id) }
            outgoing.remove(at: i)
        case .failure(.noAnswer), .failure(.closed):
            // It may have reached the node: only the same ref can try again safely.
            outgoing[i].status = .unanswered
        case let .failure(f):
            outgoing[i].status = .failed(Words.failure(f))
        }
    }

    // MARK: Requests

    /// Makes a request, and shows a refusal if there is one.
    func request(_ body: Body, then: @escaping (Body) -> Void = { _ in }) {
        guard let c = link.connection else {
            problem = Words.failure(.closed)
            return
        }
        c.submit(body) { [weak self] result in
            switch result {
            case let .success(answer): then(answer)
            case let .failure(f): self?.problem = Words.failure(f)
            }
        }
    }

    func saveContact(_ address: Address, name: String) {
        guard fits(name, Companion.nameMax) else { return }
        // The turned-away address stays offered until the node has saved it, so a refusal can be tried again.
        request(.saveContact(address: address, name: name)) { [weak self] _ in
            self?.asked.removeAll { $0.address == address }
        }
    }

    func removeContact(_ address: Address) { request(.removeContact(address: address)) }
    func endSession(_ address: Address) { request(.endSession(address: address)) }

    func makeGroup(_ name: String, then: @escaping (GroupID) -> Void = { _ in }) {
        guard fits(name, Companion.nameMax) else { return }
        request(.makeGroup(name: name)) { answer in
            if case let .made(group) = answer { then(group) }
        }
    }

    func nameGroup(_ group: GroupID, name: String) {
        guard fits(name, Companion.nameMax) else { return }
        request(.nameGroup(group: group, name: name))
    }

    func leaveGroup(_ group: GroupID) { request(.leaveGroup(group: group)) }
    func invite(_ address: Address, to group: GroupID) { request(.sendInvite(group: group, to: address)) }
    func join(_ invite: UInt32) { request(.join(id: invite)) }
    func set(_ setting: Setting) { request(.set(setting)) }

    func dismissAsked(_ a: Asked) { asked.removeAll { $0.address == a.address } }

    private func fits(_ text: String, _ limit: Int) -> Bool {
        guard text.utf8.count <= limit else {
            problem = "Too long: at most \(limit) bytes."
            return false
        }
        return true
    }

    // MARK: Positions

    /// Whether the node speaks positions: version 5 or later. Before it, nothing of them is offered.
    var speaksPositions: Bool { (agreed ?? 0) >= 5 }

    /// How the node shares its position with `peer`, its minutes counted down from when its record
    /// came; nil while it does not, or once those minutes have passed.
    func sharing(with peer: Peer) -> PositionSharing? {
        let found: (PositionSharing, String)? = switch peer {
        case let .contact(address): records.sharing[address].map { ($0, "sc:\(address)") }
        case let .group(group): records.groupSharing[group].map { ($0, "sg:\(group)") }
        }
        guard let found else { return nil }
        var s = found.0
        if s.minutes > 0 {
            let gone = Int(clock.timeIntervalSince(heard[found.1] ?? clock) / 60)
            // Run out: the node has turned it off, though with the link down no record said so.
            guard gone < Int(s.minutes) else { return nil }
            s.minutes = UInt16(max(1, Int(s.minutes) - gone))
        }
        return s
    }

    /// `p`, held under `key` as `heard` keys it, its age counted on from when its record came.
    func counted(_ p: Position, key: String) -> Position {
        var p = p
        let since = UInt64(max(0, clock.timeIntervalSince(heard[key] ?? clock)))
        p.age = UInt32(min(UInt64(p.age) + since, UInt64(UInt32.max)))
        return p
    }

    /// The clock positions and sharing are shown against, read every half minute so that ages and
    /// time left count on while they are on screen.
    @Published private(set) var clock = Date()
    private var ticking: AnyCancellable?

    /// When each position and sharing record held arrived: the `age` and `minutes` each gives are
    /// as of then. Keyed "c:" and an address, "g:" a group and routing id, "sc:" and "sg:" for sharing.
    private var heard: [String: Date] = [:]

    /// Notes that a position or sharing record arrived now: each one's `age` or `minutes` is as of
    /// its own frame, so one the same as the record before it still sets the time anew.
    private func noteArrival(_ body: Body) {
        let key: String
        switch body {
        case let .position(contact, _): key = "c:\(contact)"
        case let .groupPosition(group, from, _): key = "g:\(group):\(Words.routingId(from))"
        case let .sharing(contact, _): key = "sc:\(contact)"
        case let .groupSharing(group, _): key = "sg:\(group)"
        default: return
        }
        heard[key] = Date()
    }

    /// Forgets the arrival of records no longer held.
    private func forgetArrivals(_ new: Records) {
        var keys = Set<String>()
        keys.formUnion(new.positions.keys.map { "c:\($0)" })
        keys.formUnion(new.groupPositions.keys.map { "g:\($0.group):\(Words.routingId($0.from))" })
        keys.formUnion(new.sharing.keys.map { "sc:\($0)" })
        keys.formUnion(new.groupSharing.keys.map { "sg:\($0)" })
        heard = heard.filter { keys.contains($0.key) }
        clock = Date()
    }

    /// Turns sharing with `peer` on, changes it, or with `PositionSharing.off` turns it off. Only
    /// ever because the user asked, from the share sheet: the specification says a client never
    /// does it by itself. Turning it on is when the app first asks for the phone's location.
    func share(_ s: PositionSharing, with peer: Peer) {
        switch peer {
        case let .contact(address): request(.share(contact: address, s))
        case let .group(group): request(.shareGroup(group: group, s))
        }
        guard s.isOn else { return }
        if location.isUndecided {
            askedForLocation = true
            location.ask()
        } else if !location.isAllowed {
            tellNoLocation()
        }
    }

    /// The node is given the phone's position while it shares with anyone, over a node synced and
    /// speaking positions, with the user's leave: and not otherwise.
    private var wantsPosition: Bool {
        linkState == .ready && syncedOnThisLink && speaksPositions && location.isAllowed
            && (!records.sharing.isEmpty || !records.groupSharing.isEmpty)
    }

    /// The least time between two `SET_POSITION`s.
    private static let fixEvery: TimeInterval = 15
    /// The oldest last-known location given the node when the feed starts.
    private static let lastFixMax: TimeInterval = 600

    /// Starts or stops the feed of the phone's position to the node, as `wantsPosition` says, and
    /// keeps it as exact as the finest sharing needs.
    private func feedPosition() {
        guard wantsPosition else {
            location.stop()
            positionSent = nil
            return
        }
        let fine = (records.sharing.values.map(\.precision) + records.groupSharing.values.map(\.precision))
            .contains { $0 >= 20 }
        let starting = !location.isRunning
        location.start(fine: fine)
        // One now, from the last location known if it is recent: the feed's first may be a while.
        if starting, let last = location.last, -last.timestamp.timeIntervalSinceNow < Self.lastFixMax {
            give(last)
        }
    }

    /// Gives the node the phone's position, at most once each `fixEvery`. Not answered: a refusal
    /// changes nothing, and the next fix tries again.
    private func give(_ fix: CLLocation) {
        guard wantsPosition, let c = link.connection, fix.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        if let sent = positionSent, -sent.timeIntervalSinceNow < Self.fixEvery { return }
        positionSent = Date()
        let lat = Int32(clamping: Int64((fix.coordinate.latitude * 1e7).rounded()))
        let lon = Int32(clamping: Int64((fix.coordinate.longitude * 1e7).rounded()))
        // Above the WGS 84 ellipsoid, as the node's own receiver measures it; -32768 is none.
        var altitude = Position.noAltitude
        if fix.verticalAccuracy > 0 {
            altitude = Int16(max(-32767, min(32767, fix.ellipsoidalAltitude.rounded())))
        }
        let accuracy = fix.horizontalAccuracy > 0
            ? UInt16(min(max(fix.horizontalAccuracy.rounded(.up), 1), 65535)) : 0
        let age = UInt16(min(max(-fix.timestamp.timeIntervalSinceNow, 0), 65535))
        c.submit(.setPosition(lat: lat, lon: lon, altitude: altitude, accuracy: accuracy, age: age))
    }

    private func locationAuthorizationChanged() {
        locationAllowed = location.isAllowed
        if location.isAllowed {
            UserDefaults.standard.removeObject(forKey: Self.toldNoLocationKey)
        } else if askedForLocation, !location.isUndecided {
            tellNoLocation()
        }
        if !location.isUndecided { askedForLocation = false }
        feedPosition()
    }

    /// Says once, until the user allows it, what sharing is without the phone's location.
    private func tellNoLocation() {
        guard !UserDefaults.standard.bool(forKey: Self.toldNoLocationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.toldNoLocationKey)
        // After the share sheet has gone: an alert over a sheet on its way out is lost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.notice = "Without location access the node shares only what its own receiver finds, if it has one."
        }
    }

    // MARK: Firmware

    /// Asks the site for its latest release, and finds the image in it for the node.
    func checkForUpdate() {
        // Not until the first sync is done: the region held is not yet the node's.
        guard linkState == .ready, let board, !board.isEmpty else { return }
        guard let region = records.me?.region, !region.isEmpty else {
            firmwareStatus = .nothing("Set the node's region first: each region has its own image.")
            return
        }
        let running = release ?? ""
        checkedAgainst = running
        firmwareStatus = .checking
        firmwareTask?.cancel()
        firmwareTask = Task { [weak self] in
            let status: FirmwareStatus
            do {
                let manifest = try FirmwareManifest(json: try await Self.fetch(FirmwareManifest.latest, fresh: true))
                if let image = manifest.image(board: board, region: region) {
                    status = .found(FirmwareOffer(
                        release: manifest.release, image: image, comparison: manifest.compared(to: running)))
                } else {
                    status = .nothing("There is no firmware for \(board) in \(region) in release \(manifest.release).")
                }
            } catch is CancellationError {
                return
            } catch is FirmwareManifest.ReadError {
                status = .failed("The list of releases could not be read.")
            } catch {
                status = .failed("Could not reach ternmesh.org. \(error.localizedDescription)")
            }
            guard let self, !Task.isCancelled else { return }
            self.firmwareStatus = status
        }
    }

    /// Downloads the image offered, checks it, and sends it to the node.
    func update() {
        guard linkState == .ready, case let .found(offer) = firmwareStatus, let id = remembered else { return }
        guard stillFor(offer) else { return }
        updateNode = id
        if let d = downloaded, d.image == offer.image { return send(d.bytes, offer) }
        firmwareStatus = .downloading(offer)
        firmwareTask?.cancel()
        firmwareTask = Task { [weak self] in
            let failure: String
            do {
                let bytes = try await Self.fetch(offer.image.url, fresh: false)
                let image = offer.image
                // A megabyte's digest takes a moment: not on the main thread.
                let good = await Task.detached(priority: .userInitiated) { image.matches(bytes) }.value
                guard let self, !Task.isCancelled else { return }
                guard good else {
                    self.firmwareStatus = .failed("The image downloaded is not the one the release lists. Try again.")
                    return
                }
                self.downloaded = (image, bytes)
                self.send(bytes, offer)
                return
            } catch is CancellationError {
                return
            } catch {
                failure = "Could not download the firmware. \(error.localizedDescription)"
            }
            guard let self, !Task.isCancelled else { return }
            self.firmwareStatus = .failed(failure)
        }
    }

    /// Stops a download, or the sending: the node keeps what it was sent until it restarts, and
    /// updating again goes on from there.
    func cancelUpdate() {
        switch firmwareStatus {
        case let .downloading(offer):
            firmwareTask?.cancel()
            firmwareTask = nil
            firmwareStatus = .found(offer)
        case .sending:
            updater?.cancel()
        default:
            break
        }
    }

    /// Whether the node is still what the offer was chosen for, asked again before downloading and
    /// before sending: the node's region may have changed since the check, by this client or another
    /// (and a sync may have only just said so), and so may its firmware, so that what was newer is
    /// not. An image is for one board and one region.
    private func stillFor(_ offer: FirmwareOffer) -> Bool {
        guard offer.image.board.lowercased() == board?.lowercased(),
              offer.image.region.lowercased() == records.me?.region.lowercased(),
              (release ?? "") == checkedAgainst else {
            firmwareStatus = .nothing("The node has changed since the check. Check for an update again.")
            return false
        }
        return true
    }

    private func send(_ bytes: [UInt8], _ offer: FirmwareOffer) {
        guard stillFor(offer) else { return }
        let u = Updater(image: bytes, digest: offer.image.sha256)
        updater = u
        updateOffer = offer
        u.onChange = { [weak self, weak u] in
            guard let self, let u, self.updater === u else { return }
            self.updaterChanged(u, offer)
        }
        updaterChanged(u, offer)
        // Over a link that is down, or still syncing, it waits, and goes on once the node has synced.
        if let c = link.connection, isReady { u.resume(on: c) }
    }

    private func updaterChanged(_ u: Updater, _ offer: FirmwareOffer) {
        switch u.phase {
        case .idle, .waiting, .beginning, .sending, .ending:
            let canCancel = u.phase != .ending
            let waiting = u.phase == .waiting || u.phase == .idle
            // Awake while sending; a link that is down may stay down, and the screen may sleep.
            keepAwake(!waiting)
            firmwareStatus = .sending(offer, held: u.held, size: u.size, waiting: waiting, canCancel: canCancel)
        case let .finished(outcome):
            updater = nil
            updateOffer = nil
            keepAwake(false)
            switch outcome {
            case .restarting: firmwareStatus = .restarting(offer, confirmed: true)
            case .unconfirmed: firmwareStatus = .restarting(offer, confirmed: false)
            case .cancelled: firmwareStatus = .found(offer)
            default: firmwareStatus = .failed(Words.update(outcome))
            }
        }
    }

    /// The node has synced: an update waiting for it goes on, if the node is still what it was
    /// chosen for. While the link was down another client may have changed its region or its
    /// firmware, and the sync is what says so.
    private func nodeSynced() {
        guard remembered == updateNode, let c = link.connection, let updater, let updateOffer,
              updater.phase == .waiting || updater.phase == .idle else { return }
        if stillFor(updateOffer) {
            updater.resume(on: c)
        } else {
            self.updater = nil
            self.updateOffer = nil
            keepAwake(false)
            updater.cancel()
        }
    }

    /// The node answered `HELLO`: one sent an update learns what the node now runs.
    private func nodeReturned() {
        guard remembered == updateNode else { return }
        if case let .restarting(offer, confirmed) = firmwareStatus {
            let running = release ?? ""
            let shown = running.isEmpty ? "firmware with no release" : running
            if ReleaseComparison(offered: offer.release, running: running) == .same {
                firmwareStatus = .done("Updated to \(offer.release).")
            } else if confirmed {
                firmwareStatus = .done(
                    "The node came back running \(shown): the new firmware did not start, and it went back to what it ran before.")
            } else {
                firmwareStatus = .done(
                    "The node came back running \(shown): the update did not take. Try again, and it goes on from where it stopped.")
            }
            downloaded = nil
        }
    }

    private func resetFirmware() {
        firmwareTask?.cancel()
        firmwareTask = nil
        updater?.cancel()
        updater = nil
        updateNode = nil
        downloaded = nil
        board = nil
        release = nil
        firmwareStatus = .idle
        keepAwake(false)
    }

    /// Keeps the screen on while the node is sent its firmware: Bluetooth goes on in the
    /// background, but more slowly, and a minute's lock is a while for a few minutes' update.
    private func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    private static func fetch(_ address: String, fresh: Bool) async throws -> [UInt8] {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return [UInt8](data)
    }

    // MARK: What the connection says

    private func handle(_ event: ConnectionEvent) {
        switch event {
        case let .ready(version, fw):
            firmware = fw
            nodeVersion = version
            agreed = link.connection?.agreed
            board = link.connection?.board
            release = link.connection?.release
            nodeReturned()
        case let .news(body):
            if case let .asked(address, why) = body {
                // A saved contact turned away for want of room is news too: only the offer to save
                // it is left out.
                asked.removeAll { $0.address == address }
                asked.insert(Asked(address: address, why: why, when: Date()), at: 0)
            } else if !isActive, records.isArrival(body) {
                notify(body)
            }
            noteArrival(body)
            take()
            scheduleSave()
        case .synced:
            take()
            save()
            syncedOnThisLink = true
            nodeSynced()
        case .refused, .gone, .syncRefused:
            break
        }
    }

    /// Takes what the connection now holds.
    private func take() {
        guard let c = link.connection else { return }
        forgetArrivals(c.records)
        records = c.records
        conversations = records.conversations
        setUp = remembered.map { isSetUp($0, self.records) } ?? true
        showUnread()
        // An unanswered send that the records now show the node holding went: it needs no retry.
        let records = self.records
        if outgoing.contains(where: { $0.status == .unanswered && records.holdsSent($0.text, to: $0.peer, after: $0.after) }) {
            outgoing.removeAll { $0.status == .unanswered && records.holdsSent($0.text, to: $0.peer, after: $0.after) }
        }
        markRead()
    }

    /// Marks read what the user has seen: the conversation on screen while the app is in front,
    /// and any seen before that waited behind another's unread item, as far as one `READ` can go
    /// without marking what has not been seen.
    private func markRead() {
        if isActive, let peer = visible,
           let upTo = records.items.values.filter({ $0.peer == peer }).map(\.id).max() {
            seen[peer] = max(seen[peer] ?? 0, upTo)
        }
        let records = self.records
        // What has been read since, here or on another client, needs no more telling.
        seen = seen.filter { peer, upTo in
            records.items.values.contains { $0.isUnread && $0.peer == peer && $0.id <= upTo }
        }
        guard canWrite, let c = link.connection, let through = records.readThrough(seen: seen), through != reading
        else { return }
        reading = through
        c.submit(.read(through: through)) { [weak self] result in
            self?.reading = nil
            // Refused (not now) or unanswered: ask again shortly, or what is on screen stays unread
            // until something else happens. A closed link asks again when it opens.
            if case let .failure(f) = result, f != .closed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.markRead() }
            }
        }
    }

    private func notify(_ body: Body) {
        let peer: Peer
        let text: String
        let id: UInt32
        switch body {
        case let .message(m): (peer, text, id) = (.contact(m.contact), m.text, m.id)
        case let .groupMessage(m): (peer, text, id) = (.group(m.group), m.text, m.id)
        case let .invite(i): (peer, text, id) = (.contact(i.contact), Item.invite(i).summary, i.id)
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = records.name(of: peer)
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(identifier: "item-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: On disk

    /// Deletes what the app kept of the node `id`.
    private static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        UserDefaults.standard.removeObject(forKey: outgoingKey(id))
        UserDefaults.standard.removeObject(forKey: askedKey(id))
        UserDefaults.standard.removeObject(forKey: setupKey(id))
    }

    private func keepKnown() {
        let kept = known.map { k -> [String: String] in
            ["id": k.id.uuidString, "name": k.name, "chosen": String(k.chosen.timeIntervalSince1970)]
        }
        UserDefaults.standard.set(kept, forKey: Self.knownKey)
    }

    private static func loadKnown() -> [KnownNode] {
        let kept = UserDefaults.standard.array(forKey: knownKey) as? [[String: String]] ?? []
        return kept.compactMap { d in
            guard let id = d["id"].flatMap(UUID.init(uuidString:)), let name = d["name"] else { return nil }
            let chosen = d["chosen"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            return KnownNode(id: id, name: name, chosen: chosen)
        }
        .sorted { $0.chosen > $1.chosen }
    }

    private static func file(_ id: UUID) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tern", isDirectory: true)
        return dir.appendingPathComponent("\(id.uuidString).records")
    }

    private static func load(_ id: UUID) -> Records {
        guard let data = try? Data(contentsOf: file(id)) else { return Records() }
        return Records(decoding: [UInt8](data))
    }

    /// Messages the node may or may not hold are kept too, with their `ref`s: written again after
    /// a restart under a new `ref`, one the node did take would go twice. One that was being sent
    /// when the app stopped comes back as unanswered.
    private func keepOutgoing() {
        guard let id = remembered else { return }
        let kept = outgoing.filter { $0.status == .sending || $0.status == .unanswered }.map { o -> [String: String] in
            let peer: String
            switch o.peer {
            case let .contact(a): peer = "c:\(a)"
            case let .group(g): peer = "g:\(g)"
            }
            return ["ref": String(o.ref), "peer": peer, "text": o.text, "after": String(o.after)]
        }
        UserDefaults.standard.set(kept, forKey: Self.outgoingKey(id))
    }

    /// The node does not keep an `ASKED`, and a sync does not send it again: each is kept here
    /// until the user saves the address or dismisses it.
    private func keepAsked() {
        guard let id = remembered else { return }
        let kept = asked.map { a -> [String: String] in
            ["address": a.address.description, "why": String(a.why), "when": String(a.when.timeIntervalSince1970)]
        }
        UserDefaults.standard.set(kept, forKey: Self.askedKey(id))
    }

    private static func askedKey(_ id: UUID) -> String { "org.ternmesh.tern.asked.\(id.uuidString)" }

    private static func loadAsked(_ id: UUID) -> [Asked] {
        let kept = UserDefaults.standard.array(forKey: askedKey(id)) as? [[String: String]] ?? []
        return kept.compactMap { d in
            guard let address = d["address"].flatMap(Address.init(hex:)), let why = d["why"].flatMap(UInt8.init),
                  let when = d["when"].flatMap(Double.init)
            else { return nil }
            return Asked(address: address, why: why, when: Date(timeIntervalSince1970: when))
        }
    }

    private static var launchedActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    private static func outgoingKey(_ id: UUID) -> String { "org.ternmesh.tern.outgoing.\(id.uuidString)" }

    private static func loadOutgoing(_ id: UUID) -> [Outgoing] {
        let kept = UserDefaults.standard.array(forKey: outgoingKey(id)) as? [[String: String]] ?? []
        return kept.compactMap { d in
            guard let ref = d["ref"].flatMap(UInt32.init), let key = d["peer"], let text = d["text"] else { return nil }
            let hex = String(key.dropFirst(2))
            let peer: Peer?
            if key.hasPrefix("c:") {
                peer = Address(hex: hex).map(Peer.contact)
            } else if key.hasPrefix("g:") {
                peer = GroupID(hex: hex).map(Peer.group)
            } else {
                peer = nil
            }
            let after = d["after"].flatMap(UInt32.init) ?? 0
            return peer.map { Outgoing(ref: ref, peer: $0, text: text, status: .unanswered, after: after) }
        }
    }

    /// Writes the records now. After each sync, and when the app leaves the front.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let id = remembered else { return }
        let url = Self.file(id)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(records.encoded()).write(to: url, options: .atomic)
    }

    /// Writes the records a little after news stops arriving, not once for every frame of it.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
}
