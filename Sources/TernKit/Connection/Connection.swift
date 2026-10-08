// One connection to a node, as the client's half of the specification's conversation: HELLO and
// what both versions define, one request at a time, news counted from the HELLO, a sync again
// when some was missed, and a request at least every IDLE seconds so a node on a serial port does
// not take the client for gone.
//
// It does no I/O and keeps no time of its own. Whatever carries the frames (Core Bluetooth, a
// serial port, a test) hands it each frame it receives and sends what `send` gives it; whatever
// runs the app calls `tick()` by `nextDeadline`. Everything happens on the caller's thread, so
// there is nothing to lock.

/// Why a request came to nothing.
public enum RequestFailure: Error, Equatable {
    /// The node answered `ERROR` with this code.
    case refused(code: UInt8)
    /// The node's version, or this client's, does not define the request, so it was not sent.
    case unsupported
    /// No answer within `Companion.answerWait`. It may have been acted on all the same.
    case noAnswer
    /// The connection closed before the request was answered, or was closed when it was made.
    case closed
    /// It could not be built: text longer than its field allows.
    case invalid(EncodeError)
}

/// What a connection tells the app, besides each request's answer.
public enum ConnectionEvent: Equatable {
    /// The node answered `HELLO`. `version` is the node's; the connection speaks the lesser of
    /// it and its own.
    case ready(version: UInt8, firmware: String)
    /// A news frame, already applied to `records`. `ASKED` is one, and is applied to nothing.
    case news(Body)
    /// A sync finished: `records` is the node's, as of now.
    case synced
    /// The node refused a sync with this code (8: not now). The connection asks again at the
    /// next idle deadline, in place of a `PING`.
    case syncRefused(code: UInt8)
    /// The node refused the `HELLO` with this code: 7 if the Bluetooth link's MTU is too small.
    case refused(code: UInt8)
    /// The node did not answer in time. Close the link and open it again, then call `open()`.
    case gone
}

public final class Connection {
    /// The version this client speaks.
    public let version: UInt8
    /// Everything the node has said it holds. Kept across `open()`s, so a connection that comes
    /// back asks only for what is new.
    public private(set) var records: Records
    /// The node's version and firmware, from its `INFO`.
    public private(set) var nodeVersion: UInt8?
    public private(set) var firmware: String?

    /// Sends one frame to the node: one Bluetooth write, or wrapped for a byte stream.
    public var send: ([UInt8]) -> Void = { _ in }
    public var onEvent: (ConnectionEvent) -> Void = { _ in }

    /// The version both ends speak, once the node has said its own.
    public var agreed: UInt8? { nodeVersion.map { min($0, version) } }

    /// When `tick()` next has something to do: an answer overdue, or a `PING` due. Nil while
    /// closed.
    public var nextDeadline: Double? {
        if let f = inFlight { return f.deadline }
        return phase == .open ? lastAnswer + Companion.idle : nil
    }

    private let now: () -> Double
    private let wallTime: (() -> UInt32)?

    private enum Phase { case closed, greeting, open }
    private var phase = Phase.closed
    private var seq: UInt8 = 0
    private var expectedNews: UInt8 = 0
    /// The greatest `id` held when news was first missed, until a sync that asked again from it
    /// finishes. A connection that starts has missed whatever changed while there was none.
    private var missedSince: UInt32?
    private var syncWanted = false
    /// A sync was refused: the next idle deadline asks again.
    private var syncOwed = false
    private var queue: [Pending] = []
    private var inFlight: (pending: Pending, seq: UInt8, deadline: Double)?
    private var lastAnswer = 0.0

    private struct Pending {
        enum Kind { case user(Body), hello, setTime, sync, ping }
        var kind: Kind
        var then: (Result<Body, RequestFailure>) -> Void = { _ in }

        var isUser: Bool { if case .user = kind { true } else { false } }
        var isSync: Bool { if case .sync = kind { true } else { false } }
    }

    /// - Parameters:
    ///   - now: a clock in seconds that only goes forward, for the protocol's timers.
    ///   - wallTime: seconds since 1970, to set the node's clock with after each `HELLO`; nil
    ///     to leave it.
    public init(
        version: UInt8 = Companion.version, records: Records = Records(), now: @escaping () -> Double,
        wallTime: (() -> UInt32)?
    ) {
        precondition(version <= Companion.version, "this client speaks no version past \(Companion.version)")
        self.version = version
        self.records = records
        self.now = now
        self.wallTime = wallTime
    }

    /// Starts the conversation on a link that has just opened: `HELLO`, then the clock and a sync.
    /// Requests made before the node answers wait for it.
    /// Opening again while a `HELLO` is unanswered does nothing; after the link drops, `close()`
    /// first. Requests the connection held from before fail with `.closed`, once the new `HELLO`
    /// is sent: a callback that opens again finds it opening already.
    public func open() {
        guard phase != .greeting else { return }
        let old = takeAll()
        phase = .greeting
        nodeVersion = nil
        firmware = nil
        hello()
        for p in old { p.then(.failure(.closed)) }
    }

    /// The link closed. Every request not yet answered fails with `.closed`.
    public func close() {
        phase = .closed
        records.abandonSync()
        for p in takeAll() { p.then(.failure(.closed)) }
    }

    /// Asks the node for anything it holds that this client may not.
    public func resync() {
        syncWanted = true
        pump()
    }

    /// Makes a request. `HELLO` and `SYNC` are the connection's own: use `open()` and `resync()`.
    public func submit(_ body: Body, then: @escaping (Result<Body, RequestFailure>) -> Void = { _ in }) {
        precondition(body.type.isRequestType, "\(body.name) is not a request")
        precondition(body.type != 0x01 && body.type != 0x02, "the connection says HELLO and SYNC itself")
        guard phase != .closed else { return then(.failure(.closed)) }
        guard body.since <= (agreed ?? version) else { return then(.failure(.unsupported)) }
        queue.append(Pending(kind: .user(body), then: then))
        pump()
    }

    /// Sends `text` to `to` as a new message, under a `ref` of its own; returns the `ref`. To try
    /// again after `.noAnswer`, send the same text with the same `ref`: the node sends it once.
    @discardableResult
    public func sendMessage(
        _ text: String, to: Address, ref: UInt32 = .random(in: 1...UInt32.max),
        then: @escaping (Result<Body, RequestFailure>) -> Void = { _ in }
    ) -> UInt32 {
        submit(.send(ref: ref, to: to, text: text), then: then)
        return ref
    }

    /// Sends `text` to a group, as `sendMessage` does to an address.
    @discardableResult
    public func sendToGroup(
        _ text: String, group: GroupID, ref: UInt32 = .random(in: 1...UInt32.max),
        then: @escaping (Result<Body, RequestFailure>) -> Void = { _ in }
    ) -> UInt32 {
        submit(.sendGroup(ref: ref, group: group, text: text), then: then)
        return ref
    }

    /// One frame from the node.
    public func receive(_ bytes: [UInt8]) {
        guard phase != .closed, bytes.count >= 2 else { return }
        var frame: Frame?
        var malformed = false
        do {
            frame = try Frame.decode(bytes)
        } catch DecodeError.malformed {
            malformed = true
        } catch {}
        if bytes[0].isNewsType {
            news(seq: bytes[1], frame?.body, lost: malformed)
        } else if bytes[0].isAnswerType, let f = inFlight, bytes[1] == f.seq, let frame {
            // An answer whose seq is not the request's is to one given up on, and is ignored.
            answer(f.pending, frame.body)
        }
    }

    /// Runs the timers: gives up on an overdue answer, or pings a node that has heard nothing
    /// for `Companion.idle` seconds.
    public func tick() {
        let t = now()
        if let f = inFlight {
            guard t >= f.deadline else { return }
            shutDown(.gone, unanswered: .noAnswer)
        } else if phase == .open, t >= lastAnswer + Companion.idle {
            if syncOwed {
                syncOwed = false
                resync()
            } else {
                transmit(Pending(kind: .ping))
            }
        }
    }

    // MARK: -

    private func hello() {
        records.abandonSync()
        queue.removeAll { !$0.isUser }
        transmit(Pending(kind: .hello))
    }

    /// - Parameter lost: the frame was news of a type this client knows that it could not read:
    /// a record lost as surely as one never received.
    private func news(seq: UInt8, _ body: Body?, lost: Bool) {
        guard phase == .open else { return }
        // News of a type this client does not know is ignored, but the node counted it.
        if seq != expectedNews || lost {
            // What was lost may be a record this sync would have sent: it no longer proves what
            // is gone, and the one after it will.
            if missedSince == nil { missedSince = records.greatest }
            records.abandonSync()
            syncWanted = true
        }
        expectedNews = seq &+ 1
        if let f = inFlight, f.pending.isSync {
            inFlight?.deadline = now() + Companion.answerWait
        }
        if let body, body.type.isNewsType {
            records.apply(body)
            onEvent(.news(body))
        }
        pump()
    }

    private func answer(_ p: Pending, _ body: Body) {
        inFlight = nil
        lastAnswer = now()
        switch (p.kind, body) {
        case let (.hello, .info(v, fw)):
            nodeVersion = v
            firmware = fw
            phase = .open
            expectedNews = 0
            missedSince = min(missedSince ?? .max, records.greatest)
            syncWanted = false
            syncOwed = false
            queue.insert(Pending(kind: .sync), at: 0)
            if wallTime != nil { queue.insert(Pending(kind: .setTime), at: 0) }
            onEvent(.ready(version: v, firmware: fw))
        case let (.hello, .error(code)):
            shutDown(.refused(code: code))
            return
        case (.hello, _):
            shutDown(.gone)
            return
        case (_, .error(ErrorCode.helloFirst)):
            // The node took this client for gone, and acted on nothing: start again, and ask once
            // more for what it refused.
            if p.isUser { queue.insert(p, at: 0) }
            phase = .greeting
            hello()
            return
        case let (_, .error(code)):
            if p.isSync {
                records.abandonSync()
                syncOwed = true
                onEvent(.syncRefused(code: code))
            }
            p.then(.failure(.refused(code: code)))
        case (.sync, .synced):
            if records.finishSync(version: agreed ?? version) {
                missedSince = nil
                syncOwed = false
                onEvent(.synced)
            }
            p.then(.success(body))
        default:
            p.then(.success(body))
        }
        pump()
    }

    /// Sends the next request, if none is unanswered.
    private func pump() {
        guard phase == .open, inFlight == nil else { return }
        if syncWanted, !queue.contains(where: \.isSync) {
            queue.insert(Pending(kind: .sync), at: 0)
        }
        syncWanted = false
        while !queue.isEmpty, inFlight == nil {
            let p = queue.removeFirst()
            if case let .user(body) = p.kind, body.since > (agreed ?? version) {
                p.then(.failure(.unsupported))
                continue
            }
            transmit(p)
        }
    }

    private func transmit(_ p: Pending) {
        let body: Body
        switch p.kind {
        case let .user(b): body = b
        case .hello: body = .hello(version: version)
        case .setTime: body = .setTime(wallTime?() ?? 0)
        case .ping: body = .ping
        case .sync:
            // What was missed stays marked until a sync finishes: one refused, given up on or
            // abandoned asks again from the same place.
            body = .sync(after: records.after(version: agreed ?? version, missedSince: missedSince))
            records.beginSync()
        }
        seq &+= 1
        let bytes: [UInt8]
        do {
            bytes = try Frame(seq: seq, body: body).encode()
        } catch let e as EncodeError {
            return p.then(.failure(.invalid(e)))
        } catch {
            return p.then(.failure(.closed))
        }
        inFlight = (p, seq, now() + Companion.answerWait)
        send(bytes)
    }

    /// Closes on the node's account. Everything is cleared, and the app told, before any request's
    /// callback runs: an app that opens again from either keeps what it opens.
    private func shutDown(_ event: ConnectionEvent, unanswered: RequestFailure = .closed) {
        phase = .closed
        records.abandonSync()
        let first = inFlight?.pending
        inFlight = nil
        let rest = queue
        queue = []
        onEvent(event)
        first?.then(.failure(unanswered))
        for p in rest { p.then(.failure(.closed)) }
    }

    /// Every request held, unanswered or waiting, which the connection then no longer holds. A
    /// caller fails them only once its own state is settled, since a callback may open again.
    private func takeAll() -> [Pending] {
        let pending = (inFlight.map { [$0.pending] } ?? []) + queue
        inFlight = nil
        queue = []
        return pending
    }
}
