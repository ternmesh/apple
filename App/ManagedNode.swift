// A node the user manages over the mesh, as one of its owners, through the node the app is
// connected to: what its last sync said of it, the request on its way and the step it is at, a
// setting on trial, and what came to nothing. The Manage screen reads it and asks it to act, and
// the owner check asks it whether the user's node is an owner; `Remote`, in TernKit, does the asking.
// It lives in the model, not a screen: what is asked goes on when the user leaves the screen or the
// app, as long as the link does, and stops only when they say Stop. What became of it is said where
// they are: on the screen, in a notice, or in a notification.

import Combine
import Foundation
import TernKit

@MainActor
final class ManagedNode: ObservableObject {
    let address: Address
    /// What the managed node's last sync said of it.
    @Published private(set) var records = Records()
    @Published private(set) var synced = false
    @Published private(set) var firmware: String?
    @Published private(set) var nodeVersion: UInt8?
    /// The step the request on its way is at, in words, while one is; nil when nothing is asked.
    @Published private(set) var working: String?
    /// What is being asked, in words, while anything is.
    @Published private(set) var asking: String?
    /// Said while a request waits for a node known to sleep: how long it may take.
    @Published private(set) var asleep: String?
    /// What the last check of whether the user's node is an owner found; nil before one, and while
    /// one is under way.
    @Published private(set) var checked: Check?
    /// The node said the user's node is not one of its owners, until it answers again.
    @Published private(set) var notOwner = false
    /// When the setting last changed goes back unless the node hears from an owner again; nil when
    /// none is on trial.
    @Published private(set) var trialEnds: Date?
    /// The node is restarting to apply a role or a power, and the confirming `PING` waits for it.
    @Published private(set) var settling = false
    /// Said once a setting was confirmed, until the next is changed.
    @Published private(set) var confirmed = false
    /// What came to nothing, once.
    @Published var problem: String?
    /// The node said it restarts: until it answers again.
    @Published private(set) var restarting = false
    /// How many of its screens are showing it: what became of a request is said there, not apart.
    var shown = 0
    /// Told what became of a check, or of a request the user made, once it is over.
    var onOutcome: (Words.ManageOutcome) -> Void = { _ in }
    /// Told when it starts or stops asking anything.
    var onBusy: () -> Void = {}
    /// A check of whether the user's node is an owner is under way.
    private var checking = false

    enum Check: Equatable {
        case owner, notOwner, noAnswer
        case failed(String)
    }

    private let remote: Remote
    private let now: () -> Double
    /// The name the user knows the node by.
    private let name: () -> String
    private var ticking: AnyCancellable?

    /// `wake` is what the app's node holds of how long this one sleeps; `owner` is told what each
    /// answer says of whether the user's node is one of its owners.
    init(
        address: Address, now: @escaping () -> Double, name: @escaping () -> String,
        wake: @escaping () -> UInt16?, owner: @escaping (Bool) -> Void,
        submit: @escaping (Body, @escaping (Result<Body, RequestFailure>) -> Void) -> Void
    ) {
        self.address = address
        self.now = now
        self.name = name
        remote = Remote(address: address, now: now, submit: submit)
        remote.wakeHint = wake
        remote.onOwner = { [weak self] isOwner in
            self?.notOwner = !isOwner
            owner(isOwner)
        }
        remote.onChange = { [weak self] in self?.update() }
    }

    /// Asks the node `HELLO`, and only that: an answer says the user's node is one of its owners,
    /// `ERROR` 15 that it is not, and silence nothing.
    func check() {
        guard !checking else { return }
        checked = nil
        checking = true
        remote.greet { [weak self] result in
            guard let self else { return }
            self.checking = false
            switch result {
            case .success: self.checked = .owner
            case .failure(.notAnOwner): self.checked = .notOwner
            case .failure(.noAnswer), .failure(.notDelivered): self.checked = .noAnswer
            case .failure(.cancelled): self.checked = nil
            case let .failure(f): self.checked = .failed(Words.manage(f))
            }
            switch self.checked {
            case .owner?: self.onOutcome(.owner)
            case .notOwner?: self.onOutcome(.notOwner)
            case .noAnswer?: self.onOutcome(.noAnswer)
            case let .failed(why)?: self.onOutcome(.failed(why))
            case nil: break
            }
            self.update()
        }
        update()
    }

    var isBusy: Bool { working != nil }

    /// The version both ends speak, once the managed node has answered.
    var agreed: UInt8? { remote.agreed }

    /// Asks for the node's state: itself, its contacts and neighbours.
    func refresh() {
        remote.refresh { [weak self] result in self?.settle(result) }
    }

    /// Changes a setting, on trial until the node hears from this owner again, which the remote
    /// sees to with a `PING` at once, or, for a role or a power, once the node has restarted. Then
    /// asks for the node's state again, to show what it holds now.
    func set(_ setting: Setting) {
        confirmed = false
        remote.request(.set(setting)) { [weak self] result in
            guard let self else { return }
            self.settle(result, .set(setting))
            if case .success = result { self.remote.refresh { [weak self] in self?.settle($0) } }
        }
    }

    /// Sends the `PING` that ends a trial, after it did not arrive.
    func confirm() { remote.confirm() }

    /// Makes `contact`, one of the managed node's contacts, one of its owners, or not.
    func setOwner(_ contact: Address, _ owner: Bool) {
        remote.request(.owner(address: contact, owner: owner ? 1 : 0)) { [weak self] result in
            guard let self else { return }
            self.settle(result, .owners)
            if case .success = result { self.remote.refresh { [weak self] in self?.settle($0) } }
        }
    }

    /// Restarts the managed node. Only ever because the user asked.
    func restart() {
        remote.request(.restart) { [weak self] result in
            guard let self else { return }
            self.settle(result, .restarting)
            if case .success = result { self.restarting = true }
        }
    }

    /// Gives up on whatever is asked.
    func cancel() { remote.cancel() }

    /// One news frame from the node the app is connected to.
    func take(_ news: Body) { remote.take(news) }

    /// What became of a request; `done`, what to say of it once it is over, for one the user made.
    private func settle(_ result: Result<Body, ManageFailure>, _ done: Words.ManageOutcome? = nil) {
        switch result {
        case .success:
            restarting = false
            if let done { onOutcome(done) }
        case .failure(.cancelled):
            break
        case .failure(.notAnOwner):
            problem = Words.notAnOwner(name())
            if done != nil { onOutcome(.notOwner) }
        case .failure(.noAnswer):
            problem = Words.manage(.noAnswer)
            if done != nil { onOutcome(.noAnswer) }
        case let .failure(f):
            problem = Words.manage(f)
            if done != nil { onOutcome(.failed(Words.manage(f))) }
        }
    }

    private func update() {
        let wasBusy = working != nil
        records = remote.records
        synced = remote.synced
        firmware = remote.firmware
        nodeVersion = remote.nodeVersion
        settling = remote.settleEnds != nil
        let wasOnTrial = trialEnds != nil
        trialEnds = remote.trialEnds.map { Date(timeIntervalSinceNow: $0 - now()) }
        if wasOnTrial, trialEnds == nil, problem == nil { confirmed = true }
        asking = remote.asking.map(what)
        if remote.settleEnds != nil {
            working = Words.restartSettle
        } else if remote.asking != nil {
            working = Words.manageStep(
                remote.progress, reason: remote.reason, wait: remote.wait, tries: remote.tries, node: name(),
                sleeps: remote.wakes?.wake, delivered: remote.deliveredAt.map { now() - $0 } ?? 0,
                queued: remote.queuedAt.map { now() - $0 })
        } else {
            working = nil
        }
        // Said only when something says the node sleeps, and only before its answer is on its way,
        // and not twice: once queued with no news, the step says it is held.
        if remote.asking != nil, remote.settleEnds == nil, remote.progress != MessageState.delivered,
           remote.progress != nil || remote.queuedAt == nil, let w = remote.wakes {
            asleep = Words.asleep(name(), wake: w.wake)
        } else {
            asleep = nil
        }
        // The remote keeps no time of its own: tick it while it waits for anything.
        if remote.isBusy, ticking == nil {
            // Updated each second too, for the step that says how long it has waited.
            ticking = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.remote.tick()
                self?.update()
            }
        } else if !remote.isBusy {
            ticking = nil
        }
        if wasBusy != (working != nil) { onBusy() }
    }

    /// A request, as the screens and the indicator name it.
    private func what(_ body: Body) -> String {
        let node = name()
        switch body {
        case .hello: return checking ? Words.checking(node) : "Saying hello to \(node)…"
        case .sync: return "Asking \(node) for its state…"
        case .ping: return "Confirming the setting on \(node)…"
        case let .set(setting): return "Setting \(Words.settingInSentence(setting)) on \(node)…"
        case .owner: return "Changing \(node)'s owners…"
        case .restart: return "Restarting \(node)…"
        default: return body.name
        }
    }
}
