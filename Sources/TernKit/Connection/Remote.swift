// Managing a node over the mesh, as one of its owners: draft/managing.md in ternmesh/spec.
//
// The node the client is connected to (the manager) carries each request to the managed node in a
// `MANAGE`, and gives back each answer as `MANAGED`. A request is one companion request frame; an
// answer is companion frames, each after a length byte. `Remote` is the client's half of the
// conversation with the managed node: `HELLO` first, one request at a time, each tried again if it
// was not delivered, `HELLO` again when the managed node has restarted, and a `PING` after a `SET`
// to end its trial. Like `Connection`, it does no I/O and keeps no time of its own.

/// The frames managing is carried in, and what may be asked over the mesh.
public enum Managing {
    /// The `kind` of a message for the node that carries a request, an answer, and a notice.
    public static let requestKind: UInt8 = 0x05
    public static let answerKind: UInt8 = 0x06
    public static let noticeKind: UInt8 = 0x07

    /// The companion frames of an answer, each after its length (a `MANAGED`'s `answer`), or nil
    /// for one that is not an answer: empty, a frame of length 0, or a length that runs past its end.
    public static func unpack(_ answer: [UInt8]) -> [[UInt8]]? {
        guard answer.count <= Companion.answerMax else { return nil }
        var frames: [[UInt8]] = []
        var at = 0
        while at < answer.count {
            let n = Int(answer[at])
            guard n > 0, at + 1 + n <= answer.count else { return nil }
            frames.append(Array(answer[at + 1..<at + 1 + n]))
            at += 1 + n
        }
        return frames.isEmpty ? nil : frames
    }

    /// `frames` packed, in order, into as few answers as hold them, each at most
    /// `Companion.answerMax` bytes: what a managed node sends.
    public static func pack(_ frames: [[UInt8]]) -> [[UInt8]] {
        var answers: [[UInt8]] = []
        var answer: [UInt8] = []
        for f in frames {
            if !answer.isEmpty, answer.count + 1 + f.count > Companion.answerMax {
                answers.append(answer)
                answer = []
            }
            answer.append(UInt8(f.count))
            answer += f
        }
        if !answer.isEmpty { answers.append(answer) }
        return answers
    }

    /// Whether a managed node acts on `body` for its owners over the mesh, rather than answering
    /// `ERROR` 13: keeping it working, not using it as its own user would. A `SET` of any setting
    /// but region and passkey.
    public static func allowed(_ body: Body) -> Bool {
        switch body {
        case .hello, .sync, .ping, .setTime, .saveContact, .removeContact, .endSession, .owner, .restart: true
        case let .set(setting): setting.number != 1 && setting.number != 4
        default: false
        }
    }
}

/// Why a request to a managed node came to nothing.
public enum ManageFailure: Error, Equatable {
    /// The managed node answered `ERROR` with this code.
    case refused(code: UInt8)
    /// The node the client is connected to could not take the `MANAGE`.
    case manager(RequestFailure)
    /// The managed node's version, or this client's, does not define the request.
    case unsupported
    /// The request was not delivered, after every try.
    case notDelivered
    /// The request was delivered, or may have been, but no answer came in time: the node may be
    /// asleep or out of reach, or this client's node may not be one of its owners, to whom a node
    /// may say nothing at all.
    case noAnswer
    /// The managed node answered `ERROR` 15: this client's node is not one of its owners.
    case notAnOwner
    /// Given up: the user left, or the link to the manager closed for good.
    case cancelled
}

/// A node managed over the mesh through the one the client is connected to.
public final class Remote {
    /// The managed node's address.
    public let address: Address
    /// The version this client speaks to it.
    public let version: UInt8
    /// What the managed node's last sync said of it: itself, its contacts and neighbours, its
    /// airtime, power, fix and sleeping. Never its user's messages, groups or positions.
    public private(set) var records = Records()
    /// Whether a sync has finished: `records` is the node's as of then.
    public private(set) var synced = false
    /// The managed node's version and firmware, from its `INFO`; nil until it answers `HELLO`, and
    /// again once it has restarted.
    public private(set) var nodeVersion: UInt8?
    public private(set) var firmware: String?
    /// When a `SET` over the mesh goes back, by `now`, unless the node hears from an owner again;
    /// nil when no setting is on trial, or it was confirmed.
    public private(set) var trialEnds: Double?
    /// What became of the request on its way, as `STATE` says: waiting, sent, delivered or not
    /// delivered; nil before the manager has said, or when nothing is asked.
    public private(set) var progress: UInt8?
    /// Why the request waits, and for how long the manager thinks, in seconds, as its last `STATE`
    /// says: 0 when it is not waiting, or has said nothing.
    public private(set) var reason: UInt8 = 0
    public private(set) var wait: UInt16 = 0
    /// The request being asked now, and how many times it has been sent.
    public var asking: Body? { inFlight?.pending.body ?? queue.first?.body }
    public var tries: Int { inFlight?.tries ?? 0 }

    /// Sends a request to the manager, as `Connection.submit` does.
    public var submit: (Body, @escaping (Result<Body, RequestFailure>) -> Void) -> Void
    /// Called whenever anything above changes.
    public var onChange: () -> Void = {}
    /// Called with what an answer says of this client's node: an owner (true) when the managed node
    /// answered anything, since it answers only its owners, and not one (false) when it answered
    /// `ERROR` 15. No answer says nothing.
    public var onOwner: (Bool) -> Void = { _ in }
    /// How long the managed node sleeps between wakes, in seconds, as the client knows from
    /// elsewhere: what its node holds of it as a contact (`CONTACT`'s `wake`). nil or 0 when nothing
    /// says it sleeps. The node's own `SLEEP`, from a sync, says more, and comes first.
    public var wakeHint: () -> UInt16? = { nil }

    /// How a managed node that sleeps wakes: every `wake` seconds, listening `listen` after each.
    public struct Wakes: Equatable, Sendable {
        public var wake: Int
        public var listen: Int
        public init(wake: Int, listen: Int) {
            self.wake = wake
            self.listen = listen
        }
    }

    /// How the managed node sleeps, if it is known to: from its last sync's `SLEEP`, asleep with a
    /// keeper, else from `wakeHint`. nil when nothing says it sleeps: a node that listens all the
    /// time, or one nothing is known of.
    public var wakes: Wakes? {
        if let s = records.sleep {
            return s.state == Sleep.asleep && s.wake > 0 ? Wakes(wake: Int(s.wake), listen: Int(s.listen)) : nil
        }
        guard let w = wakeHint(), w > 0 else { return nil }
        // Its listen is not known: at most 255 s.
        return Wakes(wake: Int(w), listen: Int(UInt8.max))
    }

    /// How long, from when a request is sent, its answer may take to come back from a node that
    /// sleeps: held by its keeper until it wakes, then answered while it listens, and then
    /// `MESH_ANSWER_WAIT`. 0 for a node not known to sleep.
    public var sleepWait: Double {
        wakes.map { Double($0.wake + $0.listen) + Companion.meshAnswerWait } ?? 0
    }

    /// The version both ends speak.
    public var agreed: UInt8? { nodeVersion.map { min($0, version) } }
    public var isBusy: Bool { inFlight != nil || !queue.isEmpty || settleEnds != nil }

    /// When `tick()` next has something to do; nil while nothing is asked.
    public var nextDeadline: Double? {
        switch (inFlight?.deadline, settleEnds) {
        case let (a?, b?): min(a, b)
        case let (a, b): a ?? b
        }
    }

    /// While the managed node restarts to apply a role or a power, when it can answer again, by
    /// `now`: nothing is sent to it until then, and then the `PING` that confirms the setting.
    public private(set) var settleEnds: Double?

    /// How many times a request is sent before it is given up as not delivered.
    public static let tries = 3
    /// How long a request may wait to be delivered before it is given up, in seconds: a relay that
    /// sleeps holds it until it wakes, and a route may take a while to find.
    public static let deliveryWait = 600.0
    /// After the manager says a request was not delivered, how long its answer may still come, from
    /// a copy that arrived, before it is tried again, in seconds: tries are spaced this far apart.
    public static let lateAnswer = 15.0
    /// How long a node that restarts to apply a setting takes before it can acknowledge anything,
    /// with room to spare, in seconds. Two messages unacknowledged in a row would make the manager
    /// start first contact again.
    public static let restartSettle = 45.0

    /// Whether a node restarts to apply `setting`: a role or a power does.
    public static func restarts(_ setting: Setting) -> Bool {
        switch setting {
        case .role, .power: true
        default: false
        }
    }

    private let now: () -> Double
    private var seq: UInt8 = 0
    private var queue: [Pending] = []
    private var inFlight: InFlight?
    /// What the sync under way has sent.
    private var syncing: Records?
    /// Each `MANAGE`'s attempt, so a late answer from the manager to an earlier one is not taken.
    private var attempt = 0

    private struct Pending {
        enum Kind { case user, hello, confirm }
        var kind: Kind
        var body: Body
        var then: (Result<Body, ManageFailure>) -> Void = { _ in }
        /// Asked again once after the node said `HELLO` first, which it says after a restart.
        var greetedAgain = false
    }

    private struct InFlight {
        var pending: Pending
        var seq: UInt8
        var frame: [UInt8]
        var attempt: Int
        var tries: Int
        /// The `MANAGE`'s `id`, once the manager has queued it.
        var id: UInt32?
        /// When this try was sent.
        var sent: Double
        var deadline: Double
        var notDelivered = false
        var delivered = false
    }

    public init(
        address: Address, version: UInt8 = Companion.version, now: @escaping () -> Double,
        submit: @escaping (Body, @escaping (Result<Body, RequestFailure>) -> Void) -> Void
    ) {
        precondition(version >= 17, "managing is version 17's")
        self.address = address
        self.version = version
        self.now = now
        self.submit = submit
    }

    /// Asks the managed node `body`: one request at a time, `HELLO` first. `HELLO` itself is the
    /// remote's own, and a `SYNC` asks for the node's own state, whatever its `after`.
    public func request(_ body: Body, then: @escaping (Result<Body, ManageFailure>) -> Void = { _ in }) {
        precondition(body.type.isRequestType && body.type != 0x01, "\(body.name) is not a request to manage with")
        queue.append(Pending(kind: .user, body: body, then: then))
        pump()
    }

    /// Asks the node for its state again.
    public func refresh(then: @escaping (Result<Body, ManageFailure>) -> Void = { _ in }) {
        request(.sync(after: 0), then: then)
    }

    /// Sends a `PING`, which ends a trial: any request from an owner does.
    public func confirm() {
        guard !queue.contains(where: { $0.kind == .confirm }), inFlight?.pending.kind != .confirm else { return }
        queue.insert(Pending(kind: .confirm, body: .ping), at: 0)
        pump()
    }

    /// Says `HELLO` to the managed node, and nothing else: whether it answers says whether this
    /// client's node is one of its owners. `then` has its `INFO`, or why there was none.
    public func greet(then: @escaping (Result<Body, ManageFailure>) -> Void) {
        queue.insert(Pending(kind: .hello, body: .hello(version: version), then: then), at: 0)
        pump()
    }

    /// Gives up on everything asked. A request already sent may still be acted on.
    public func cancel() {
        let all = (inFlight.map { [$0.pending] } ?? []) + queue
        inFlight = nil
        settleEnds = nil
        queue = []
        syncing = nil
        clearProgress()
        onChange()
        for p in all { p.then(.failure(.cancelled)) }
    }

    /// One news frame from the manager: a `STATE` of the request on its way, or a `MANAGED` with
    /// the managed node's answer. Any other is not the remote's.
    public func take(_ news: Body) {
        switch news {
        case let .state(s):
            guard var f = inFlight, f.id == s.id else { return }
            progress = s.state
            reason = s.state == MessageState.waiting ? s.reason : 0
            wait = s.state == MessageState.waiting ? s.wait : 0
            // A node that sleeps answers once it wakes: until then, from when this try was sent.
            let asleep = f.sent + sleepWait
            switch s.state {
            case MessageState.delivered:
                f.delivered = true
                f.deadline = max(now() + Companion.meshAnswerWait, asleep)
            case MessageState.notDelivered:
                // Its answer may still come, from a copy that arrived: a moment for it, or, from a
                // node that sleeps, which its keeper may still hold it for, until it has woken.
                f.notDelivered = true
                f.deadline = max(now() + Self.lateAnswer, asleep)
            default:
                break
            }
            inFlight = f
            onChange()
        case let .managed(from, answer):
            guard from == address, let frames = Managing.unpack(answer) else { return }
            for bytes in frames { read(bytes) }
        default:
            break
        }
    }

    /// Runs the timers: tries again a request that was not delivered, or gives up on one.
    public func tick() {
        if let end = settleEnds, now() >= end {
            settleEnds = nil
            onChange()
            pump()
        }
        guard let f = inFlight, now() >= f.deadline else { return }
        if f.notDelivered, f.tries < Self.tries {
            send(f.pending, seq: f.seq, frame: f.frame, tries: f.tries + 1)
            return
        }
        inFlight = nil
        clearProgress()
        if f.pending.kind == .hello { failAll(f.delivered ? .noAnswer : .notDelivered, first: f.pending) }
        else { finish(f.pending, .failure(f.delivered ? .noAnswer : .notDelivered)) }
    }

    // MARK: -

    private func read(_ bytes: [UInt8]) {
        let speak = agreed ?? version
        guard let frame = try? Frame.decode(bytes, version: Frame.version(toRead: bytes, speaking: speak)) else { return }
        let body = frame.body
        if body.type.isNewsType {
            // Over the mesh a node sends news only in answer to a sync.
            if syncing != nil { syncing?.apply(body) } else { records.apply(body) }
            return
        }
        guard body.type.isAnswerType, let f = inFlight, frame.seq == f.seq else { return }
        inFlight = nil
        clearProgress()
        answer(f.pending, body)
    }

    private func answer(_ p: Pending, _ body: Body) {
        if body == .error(code: ErrorCode.notAnOwner) {
            // Not an owner: nothing else asked will be answered either, nor is it worth asking again.
            onOwner(false)
            return failAll(.notAnOwner, first: p)
        }
        // Any other answer came from a node that answers only its owners.
        onOwner(true)
        // Any request answered reached the node from an owner, which ends a trial; a `SET` that
        // the node takes starts its own, below.
        trialEnds = nil
        switch (p.kind, body) {
        case let (.hello, .info(v, fw, _, _, _)):
            nodeVersion = v
            firmware = fw
            onChange()
            p.then(.success(body))
            pump()
        case let (.hello, .error(code)):
            failAll(.refused(code: code), first: p)
        case (.hello, _):
            failAll(.refused(code: ErrorCode.malformed), first: p)
        case (_, .error(ErrorCode.helloFirst)) where !p.greetedAgain:
            // The node has restarted, as one does to apply a power or a role, and forgotten this
            // client's HELLO: say it again, and ask once more.
            var again = p
            again.greetedAgain = true
            nodeVersion = nil
            syncing = nil
            queue.insert(again, at: 0)
            onChange()
            pump()
        case let (_, .error(code)):
            syncing = nil
            finish(p, .failure(.refused(code: code)))
        case (_, .synced):
            if let s = syncing { records = s }
            syncing = nil
            synced = true
            finish(p, .success(body))
        default:
            if case let .set(setting) = p.body, body == .ok {
                // On trial: confirm it, at once, or once a node that restarts to apply it can
                // answer. If the setting has left the node out of reach, the PING does not arrive,
                // and the node takes the old value back.
                trialEnds = now() + Companion.trial
                queue.insert(Pending(kind: .confirm, body: .ping), at: 0)
                if Self.restarts(setting) { settleEnds = now() + Self.restartSettle }
            }
            if case .restart = p.body, body == .ok { nodeVersion = nil }
            finish(p, .success(body))
        }
    }

    private func finish(_ p: Pending, _ result: Result<Body, ManageFailure>) {
        onChange()
        p.then(result)
        pump()
    }

    /// The `HELLO` failed: nothing else can be asked until one is answered.
    private func failAll(_ failure: ManageFailure, first: Pending) {
        let rest = queue
        queue = []
        syncing = nil
        onChange()
        first.then(.failure(failure))
        for p in rest { p.then(.failure(failure)) }
    }

    private func pump() {
        guard inFlight == nil, settleEnds == nil, let next = queue.first else { return }
        if nodeVersion == nil, next.kind != .hello {
            queue.insert(Pending(kind: .hello, body: .hello(version: version)), at: 0)
            return pump()
        }
        let p = queue.removeFirst()
        if p.kind != .hello, p.body.since > (agreed ?? version) {
            finish(p, .failure(.unsupported))
            return
        }
        seq = seq % 255 + 1
        let frame: [UInt8]
        do {
            frame = try Frame(seq: seq, body: Connection.asSpoken(p.body, agreed ?? version)).encode()
        } catch let e as EncodeError {
            return finish(p, .failure(.manager(.invalid(e))))
        } catch {
            return finish(p, .failure(.manager(.closed)))
        }
        guard frame.count <= Companion.requestMax else {
            return finish(p, .failure(.manager(.invalid(.tooLong(field: "request", limit: Companion.requestMax)))))
        }
        if case .sync = p.body { syncing = Records() }
        send(p, seq: seq, frame: frame, tries: 1)
    }

    private func clearProgress() {
        progress = nil
        reason = 0
        wait = 0
    }

    /// Sends `frame` in a new `MANAGE`: a request tried again goes as a new message, the same frame
    /// with the same `seq`, so the node acts on whichever arrives and answers it the same.
    private func send(_ p: Pending, seq: UInt8, frame: [UInt8], tries: Int) {
        attempt += 1
        let mine = attempt
        // A node that sleeps may hold it longer than `deliveryWait` before it is delivered.
        inFlight = InFlight(
            pending: p, seq: seq, frame: frame, attempt: mine, tries: tries, sent: now(),
            deadline: now() + max(Self.deliveryWait, sleepWait))
        clearProgress()
        onChange()
        submit(.manage(ref: .random(in: 1...UInt32.max), to: address, request: frame)) { [weak self] result in
            guard let self, let f = self.inFlight, f.attempt == mine else { return }
            switch result {
            case let .success(.queued(id)):
                self.inFlight?.id = id
            case .success:
                break
            case let .failure(failure):
                self.inFlight = nil
                self.clearProgress()
                if f.pending.kind == .hello {
                    self.failAll(.manager(failure), first: f.pending)
                } else {
                    self.syncing = nil
                    self.finish(f.pending, .failure(.manager(failure)))
                }
            }
        }
    }
}
