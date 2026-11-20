// A node the user manages over the mesh, as one of its owners, through the node the app is
// connected to: what its last sync said of it, the request on its way and the step it is at, a
// setting on trial, and what came to nothing. The Manage screen reads it and asks it to act, and
// the owner check asks it whether the user's node is an owner; `Remote`, in TernKit, does the asking.

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
        checked = nil
        remote.greet { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.checked = .owner
            case .failure(.notAnOwner): self.checked = .notOwner
            case .failure(.noAnswer), .failure(.notDelivered): self.checked = .noAnswer
            case .failure(.cancelled): self.checked = nil
            case let .failure(f): self.checked = .failed(Words.manage(f))
            }
        }
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
            self.settle(result)
            if case .success = result { self.remote.refresh { [weak self] in self?.settle($0) } }
        }
    }

    /// Sends the `PING` that ends a trial, after it did not arrive.
    func confirm() { remote.confirm() }

    /// Makes `contact`, one of the managed node's contacts, one of its owners, or not.
    func setOwner(_ contact: Address, _ owner: Bool) {
        remote.request(.owner(address: contact, owner: owner ? 1 : 0)) { [weak self] result in
            guard let self else { return }
            self.settle(result)
            if case .success = result { self.remote.refresh { [weak self] in self?.settle($0) } }
        }
    }

    /// Restarts the managed node. Only ever because the user asked.
    func restart() {
        remote.request(.restart) { [weak self] result in
            guard let self else { return }
            self.settle(result)
            if case .success = result { self.restarting = true }
        }
    }

    /// Gives up on whatever is asked.
    func cancel() { remote.cancel() }

    /// One news frame from the node the app is connected to.
    func take(_ news: Body) { remote.take(news) }

    private func settle(_ result: Result<Body, ManageFailure>) {
        switch result {
        case .success:
            restarting = false
        case .failure(.cancelled):
            break
        case .failure(.notAnOwner):
            problem = Words.notAnOwner(name())
        case let .failure(f):
            problem = Words.manage(f)
        }
    }

    private func update() {
        records = remote.records
        synced = remote.synced
        firmware = remote.firmware
        nodeVersion = remote.nodeVersion
        settling = remote.settleEnds != nil
        let wasOnTrial = trialEnds != nil
        trialEnds = remote.trialEnds.map { Date(timeIntervalSinceNow: $0 - now()) }
        if wasOnTrial, trialEnds == nil, problem == nil { confirmed = true }
        asking = remote.asking.map(Self.what)
        if remote.settleEnds != nil {
            working = Words.restartSettle
        } else if remote.asking != nil {
            working = Words.manageStep(
                remote.progress, reason: remote.reason, wait: remote.wait, tries: remote.tries, node: name())
        } else {
            working = nil
        }
        // Said only when something says the node sleeps, and only before its answer is on its way.
        if remote.asking != nil, remote.settleEnds == nil, remote.progress != MessageState.delivered,
           let w = remote.wakes {
            asleep = Words.asleep(name(), wake: w.wake)
        } else {
            asleep = nil
        }
        // The remote keeps no time of its own: tick it while it waits for anything.
        if remote.isBusy, ticking == nil {
            ticking = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.remote.tick()
            }
        } else if !remote.isBusy {
            ticking = nil
        }
    }

    /// A request, as the screen names it.
    private static func what(_ body: Body) -> String {
        switch body {
        case .hello: "Checking you're an owner"
        case .sync: "Asking for its state"
        case .ping: "Confirming"
        case .set: "Changing the setting"
        case .owner: "Changing its owners"
        case .restart: "Restarting it"
        default: body.name
        }
    }
}
