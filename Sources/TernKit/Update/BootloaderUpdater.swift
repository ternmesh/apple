// One DFU package, given to a node by its bootloader, as the specification's "By the bootloader"
// says: UPDATE_BOOTLOADER over the companion protocol, then, once the node has restarted into its
// bootloader, the package over the bootloader's own service (DFU.swift). The node comes back as
// itself running the image, and its next `INFO`'s `release` says so; that is the app's to read.
//
// The bootloader is another device to Bluetooth: it advertises its own service, and on iOS it has
// another identifier than the node. The finder looks for it by that service.

/// What finds a bootloader advertising the DFU service, and connects to it.
public protocol BootloaderFinder: AnyObject {
    /// Looks for a bootloader for up to `seconds`, connects to the first found and subscribes to
    /// its control point; nil if none was found or it could not be connected to.
    func find(within seconds: Double) async -> DFUTransport?
    /// Lets go of the bootloader found, if the link to it is still up.
    func disconnect()
}

/// How an update by the bootloader ended.
public enum BootloaderOutcome: Equatable, Sendable {
    /// The bootloader took the image, checked it, and is starting it. The node's next `INFO`
    /// says what it runs.
    case activated
    /// The node refused `UPDATE_BOOTLOADER` with this code: 5 (`ErrorCode.noRoom`) if it is not
    /// updated by its bootloader. It did not restart.
    case refused(code: UInt8)
    /// The node's version, or the connection's, does not define `UPDATE_BOOTLOADER`.
    case unsupported
    /// The node answered something `UPDATE_BOOTLOADER` is not answered with.
    case confused
    /// No bootloader was found advertising: the node may not have restarted into it, or may
    /// still be on its way.
    case notFound
    /// The bootloader stopped, or the link to it went. It waits for an image over Bluetooth, so
    /// trying again finds it.
    case failed(DFUError)
    /// Stopped by the task's cancellation, while sending: the bootloader waits, as for `failed`.
    case cancelled
}

public final class BootloaderUpdater {
    public enum Phase: Equatable, Sendable {
        case idle
        /// `UPDATE_BOOTLOADER` sent.
        case asking
        /// Looking for the bootloader, and connecting to it.
        case looking
        /// The DFU under way.
        case transferring(DFUProgress)
        case finished(BootloaderOutcome)
    }

    public let package: DFUPackage
    public private(set) var phase = Phase.idle {
        didSet { onChange() }
    }
    /// Whether the node was asked to restart into its bootloader and said it would, or may have:
    /// from then on, until the image is activated, it is the bootloader that is waiting.
    public private(set) var inBootloader = false
    public var onChange: () -> Void = {}

    public init(package: DFUPackage) {
        self.package = package
    }

    /// Runs the update to its end. With `node`, the node is first asked to restart into its
    /// bootloader; without, the bootloader is looked for at once, as after an update that failed
    /// part of the way, which left it waiting. Runs on the caller's actor: the connection, and
    /// `onChange`, are touched only there.
    @discardableResult
    public func run(
        asking node: UpdateLink?, finder: BootloaderFinder, isolation: isolated (any Actor)? = #isolation
    ) async -> BootloaderOutcome {
        let outcome = await go(node, finder, isolation)
        if outcome == .activated { inBootloader = false }
        phase = .finished(outcome)
        return outcome
    }

    private func go(
        _ node: UpdateLink?, _ finder: BootloaderFinder, _ isolation: isolated (any Actor)?
    ) async -> BootloaderOutcome {
        if let node {
            phase = .asking
            switch await Self.ask(node, isolation) {
            case .success(.ok):
                break
            case .success:
                return .confused
            case .failure(.noAnswer), .failure(.closed):
                // Not sent again: the node may be restarting into its bootloader. Look for it.
                break
            case let .failure(.refused(code)):
                return .refused(code: code)
            case .failure(.unsupported):
                return .unsupported
            case .failure(.invalid):
                return .confused
            }
        }
        inBootloader = true
        // A bootloader left part of the way through an earlier session restarts once told, and
        // is looked for again; once.
        for attempt in 0..<2 {
            phase = .looking
            guard let transport = await finder.find(within: DFU.findWait) else { return .notFound }
            let client = DFUClient(package: package)
            client.onProgress = { [weak self] p in self?.phase = .transferring(p) }
            defer { finder.disconnect() }
            do {
                try await client.run(transport, isolation: isolation)
                return .activated
            } catch DFUError.wasMidSession where attempt == 0 {
                continue
            } catch DFUError.cancelled {
                return .cancelled
            } catch let e as DFUError {
                return .failed(e)
            } catch {
                return .failed(.lost)
            }
        }
        return .failed(.wasMidSession)
    }

    private static func ask(_ node: UpdateLink, _ isolation: isolated (any Actor)?) async -> Result<Body, RequestFailure> {
        await withCheckedContinuation { c in
            node.submit(.updateBootloader) { c.resume(returning: $0) }
        }
    }
}
