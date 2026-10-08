// The app's one model: the Bluetooth link to the node, the connection over it, and the records
// it leaves, kept on disk between runs. The screens read what it publishes and ask it to act;
// they never touch the connection themselves.

import Combine
import Foundation
import TernKit
import UserNotifications
#if os(iOS)
import UIKit
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

/// Someone not in the contacts tried to reach the node, and was refused.
struct Asked: Identifiable, Equatable {
    var id: Address { address }
    var address: Address
    var why: UInt8
    var when: Date
}

@MainActor
final class NodeModel: ObservableObject {
    @Published private(set) var linkState: BluetoothLink.State = .starting
    @Published private(set) var found: [FoundNode] = []
    @Published private(set) var remembered: UUID?
    @Published private(set) var nodeName: String?
    @Published private(set) var records = Records()
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var outgoing: [Outgoing] = [] {
        didSet { keepOutgoing() }
    }
    @Published private(set) var asked: [Asked] = [] {
        didSet { keepAsked() }
    }
    @Published private(set) var firmware: String?
    @Published private(set) var nodeVersion: UInt8?
    /// The version both ends speak, once the node has answered.
    @Published private(set) var agreed: UInt8?
    /// A refusal or failure to show the user, once.
    @Published var problem: String?

    /// The conversation on screen, which is read as it arrives.
    var visible: Peer? {
        didSet { markRead() }
    }

    /// Whether the app is in front: notifications are only for when it is not.
    /// iOS may launch the app in the background to restore its Bluetooth link, with no scene
    /// becoming active: it starts as the application is, not as active.
    var isActive = NodeModel.launchedActive {
        didSet {
            if isActive { markRead() } else { save() }
        }
    }

    private let link: BluetoothLink
    private var saveTask: Task<Void, Never>?
    /// The `through` of a `READ` not yet answered, so the same one is not sent twice.
    private var reading: UInt32?
    private static let nameKey = "org.ternmesh.tern.nodeName"

    init() {
        link = BluetoothLink()
        remembered = link.remembered
        nodeName = UserDefaults.standard.string(forKey: Self.nameKey)
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Connecting

    func startScanning() { link.startScanning() }
    func stopScanning() { link.stopScanning() }

    func connect(to node: FoundNode) {
        if remembered != node.id {
            save()
            // The node first: what is set below is kept on disk under it.
            remembered = node.id
            records = Self.load(node.id)
            conversations = records.conversations
            outgoing = Self.loadOutgoing(node.id)
            asked = Self.loadAsked(node.id)
        }
        remembered = node.id
        nodeName = node.name
        UserDefaults.standard.set(node.name, forKey: Self.nameKey)
        link.connect(to: node.id)
    }

    func retry() { link.retry() }

    /// Forgets the node, and what the app kept of it.
    func forget() {
        // The node goes first: closing the link settles sends in flight, and with no node they
        // are not written back under it.
        let id = remembered
        remembered = nil
        link.forget()
        if let id {
            try? FileManager.default.removeItem(at: Self.file(id))
            UserDefaults.standard.removeObject(forKey: Self.outgoingKey(id))
            UserDefaults.standard.removeObject(forKey: Self.askedKey(id))
        }
        nodeName = nil
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        records = Records()
        conversations = []
        outgoing = []
        asked = []
        firmware = nil
        nodeVersion = nil
        agreed = nil
    }

    var isConnected: Bool { linkState == .ready || linkState == .syncing }

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
        outgoing.append(Outgoing(ref: ref, peer: peer, text: text, status: .sending, after: records.greatest))
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
        case .success:
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

    // MARK: What the connection says

    private func handle(_ event: ConnectionEvent) {
        switch event {
        case let .ready(version, fw):
            firmware = fw
            nodeVersion = version
            agreed = link.connection?.agreed
        case let .news(body):
            if case let .asked(address, why) = body {
                // A saved contact turned away for want of room is news too: only the offer to save
                // it is left out.
                asked.removeAll { $0.address == address }
                asked.insert(Asked(address: address, why: why, when: Date()), at: 0)
            } else if !isActive, records.isArrival(body) {
                notify(body)
            }
            take()
            scheduleSave()
        case .synced:
            take()
            save()
        case .refused, .gone, .syncRefused:
            break
        }
    }

    /// Takes what the connection now holds.
    private func take() {
        guard let c = link.connection else { return }
        records = c.records
        conversations = records.conversations
        // An unanswered send that the records now show the node holding went: it needs no retry.
        let records = self.records
        if outgoing.contains(where: { $0.status == .unanswered && records.holdsSent($0.text, to: $0.peer, after: $0.after) }) {
            outgoing.removeAll { $0.status == .unanswered && records.holdsSent($0.text, to: $0.peer, after: $0.after) }
        }
        markRead()
    }

    /// Marks read what the user can see: the conversation on screen, while the app is in front,
    /// as far as `READ` can go without marking another conversation's.
    private func markRead() {
        guard isActive, let peer = visible, isConnected, let c = link.connection,
              let through = records.readThrough(showing: peer), through != reading
        else { return }
        reading = through
        c.submit(.read(through: through)) { [weak self] _ in self?.reading = nil }
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
