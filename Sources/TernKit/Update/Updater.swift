// One image, sent to a node over the companion protocol, as the specification's "Updating the
// firmware" says: UPDATE_BEGIN, on from the offset the node answers, UPDATE_DATA of UPDATE_CHUNK
// bytes at a time, then UPDATE_END.
//
// Like the connection it drives, it does no I/O and keeps no time: it makes its requests through
// the connection, one at a time, and the connection's own wait gives up on an answer. When the
// link drops it waits, and goes on from wherever the node says once `resume(on:)` is called on a
// connection that has opened again: the node keeps an update under way until it restarts.

/// What an updater asks a node through: a `Connection`.
public protocol UpdateLink: AnyObject {
    func submit(_ body: Body, then: @escaping (Result<Body, RequestFailure>) -> Void)
}

extension Connection: UpdateLink {}

/// How an update ended.
public enum UpdateOutcome: Equatable, Sendable {
    /// The node answered `UPDATE_END` with `OK`, and is restarting into the image. Its next
    /// `INFO`'s `release` says whether it runs it: a node goes back to the firmware it ran before
    /// if the image does not start.
    case restarting
    /// `UPDATE_END` went unanswered, and is not sent again: the node may be restarting into the
    /// image. Wait for it, and read `release` in its next `INFO`.
    case unconfirmed
    /// The node refused with this code: 5 (`ErrorCode.noRoom`) if it cannot hold the image or
    /// cannot be updated over this protocol at all, 11 (`ErrorCode.notAnImage`) if the image is not
    /// one it runs, which it then discards.
    case refused(code: UInt8)
    /// The node's version, or the connection's, does not define updates.
    case unsupported
    /// The node answered something no request of an update is answered with.
    case confused
    case cancelled
}

public final class Updater {
    public enum Phase: Equatable, Sendable {
        /// Not started.
        case idle
        /// `UPDATE_BEGIN` sent: asking where to go on from.
        case beginning
        case sending
        /// `UPDATE_END` sent. Too late to cancel.
        case ending
        /// The link went. `resume(on:)` goes on once a connection is open again.
        case waiting
        case finished(UpdateOutcome)
    }

    /// How many answers in a row may be given up on before the updater waits for the link to
    /// come back. A `Connection` closes on the first, so this is for links that do not.
    public static let triesWithoutAnswer = 3
    /// How many times in a row the node may say the update is not where it was sent, with nothing
    /// held between, before the updater stops asking.
    public static let triesNotThere = 3

    public let image: [UInt8]
    public let digest: Digest
    public private(set) var phase = Phase.idle
    /// How many bytes of the image the node has said it holds.
    public private(set) var held = 0
    public var size: Int { image.count }
    /// The share of the image the node holds, from 0 to 1.
    public var progress: Double { Double(held) / Double(size) }

    /// Called whenever `phase` or `held` changes.
    public var onChange: () -> Void = {}

    private var link: UpdateLink?
    /// Bumped on each start, resume and finish: an answer to a request from before is ignored.
    private var generation = 0
    private var cancelWanted = false
    private var unanswered = 0
    private var notThere = 0

    /// - Parameters:
    ///   - image: the whole image, at least one byte.
    ///   - digest: its SHA-256, worked out if not given. A node refuses `UPDATE_END` with error 11
    ///     if it is not the image's.
    public init(image: [UInt8], digest: Digest? = nil) {
        precondition(!image.isEmpty && image.count <= Int(UInt32.max), "an image is 1 to 2^32 - 1 bytes")
        self.image = image
        self.digest = digest ?? SHA256.hash(image)
    }

    /// Whether the updater is done, one way or another.
    public var isFinished: Bool { if case .finished = phase { true } else { false } }

    /// Begins on `link`, or goes on there after the link went. Does nothing while a request is
    /// out, or once finished: a connection that starts again after `ERROR` 6 sends that request
    /// again itself.
    public func resume(on link: UpdateLink) {
        switch phase {
        case .idle, .waiting: break
        default: return
        }
        self.link = link
        generation += 1
        unanswered = 0
        if cancelWanted { return finish(.cancelled) }
        begin()
    }

    /// Stops sending. The node keeps what it holds until it restarts or another update begins,
    /// so the same image goes on from there if started again. Returns false once `UPDATE_END` is
    /// out, or the update has finished: too late to stop.
    @discardableResult
    public func cancel() -> Bool {
        switch phase {
        case .ending, .finished: return false
        case .idle, .waiting:
            finish(.cancelled)
        case .beginning, .sending:
            // The request out is answered first: one at a time.
            cancelWanted = true
        }
        return true
    }

    // MARK: -

    private func begin() {
        set(.beginning)
        request(.updateBegin(size: UInt32(size), digest: digest)) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.updating(offset)):
                unanswered = 0
                // A node holds no more than the image: one that says so is asked from the end,
                // and `UPDATE_END` finds out what it holds.
                held = min(Int(offset), size)
                next()
            case .success:
                finish(.confused)
            case .failure(.noAnswer):
                // `UPDATE_BEGIN` for the same image is safe to send again.
                again { self.begin() }
            case let .failure(f):
                failed(f)
            }
        }
    }

    private func next() {
        if cancelWanted { return finish(.cancelled) }
        if held >= size { end() } else { data(at: held) }
    }

    private func data(at offset: Int) {
        set(.sending)
        let chunk = Array(image[offset..<min(offset + Companion.updateChunk, size)])
        request(.updateData(offset: UInt32(offset), data: chunk)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.ok):
                unanswered = 0
                notThere = 0
                held = offset + chunk.count
                next()
            case .success:
                finish(.confused)
            case .failure(.refused(ErrorCode.notThere)):
                misplaced(then: begin)
            case .failure(.noAnswer):
                // A node answers the same bytes at the same offset again with OK, held once, so
                // the chunk whose answer was lost goes again.
                again { self.data(at: offset) }
            case let .failure(f):
                failed(f)
            }
        }
    }

    private func end() {
        set(.ending)
        request(.updateEnd) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.ok):
                finish(.restarting)
            case .success:
                finish(.confused)
            case .failure(.refused(ErrorCode.notThere)):
                // The node holds fewer bytes than the image: it said so, and is not restarting.
                misplaced(then: begin)
            case let .failure(.refused(code)):
                finish(.refused(code: code))
            case .failure(.unsupported):
                finish(.unsupported)
            case .failure(.noAnswer), .failure(.closed), .failure(.invalid):
                // Never sent again: the node may be restarting into the image.
                finish(.unconfirmed)
            }
        }
    }

    /// A request given up on, to be sent again, or the link waited for after too many.
    private func again(_ resend: @escaping () -> Void) {
        unanswered += 1
        if cancelWanted { return finish(.cancelled) }
        if unanswered >= Self.triesWithoutAnswer {
            link = nil
            return set(.waiting)
        }
        resend()
    }

    /// `ERROR` 10: ask the node where it is, unless it has said so too often with nothing between.
    private func misplaced(then resend: () -> Void) {
        notThere += 1
        if cancelWanted { return finish(.cancelled) }
        guard notThere < Self.triesNotThere else { return finish(.refused(code: ErrorCode.notThere)) }
        resend()
    }

    private func failed(_ f: RequestFailure) {
        switch f {
        case .closed:
            link = nil
            if cancelWanted { return finish(.cancelled) }
            set(.waiting)
        case let .refused(code): finish(.refused(code: code))
        case .unsupported: finish(.unsupported)
        case .noAnswer, .invalid: finish(.confused)
        }
    }

    private func request(_ body: Body, then: @escaping (Result<Body, RequestFailure>) -> Void) {
        guard let link else { return then(.failure(.closed)) }
        let g = generation
        link.submit(body) { [weak self] result in
            guard let self, g == self.generation else { return }
            then(result)
        }
    }

    private func finish(_ outcome: UpdateOutcome) {
        generation += 1
        link = nil
        cancelWanted = false
        set(.finished(outcome))
    }

    private func set(_ p: Phase) {
        phase = p
        onChange()
    }
}
