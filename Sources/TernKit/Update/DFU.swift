// A node's firmware, given to its bootloader: Nordic Semiconductor's legacy DFU over Bluetooth LE,
// the DFU service of the nRF5 SDK 11, as Adafruit's nRF52 bootloader speaks it. A node whose
// `INFO` says `update` 2 restarts into that bootloader when asked (`UPDATE_BOOTLOADER`), and the
// bootloader, not the companion protocol, takes the image. This is written from that protocol as
// the firmware's tools/ble_dfu.py drives it, with the same steps, waits and pace:
//
//   control  START_DFU, application          01 04
//   packet   sizes: SoftDevice, bootloader, application, u32 each, little-endian
//            <- 10 01 01                      once the bootloader has erased the application
//   control  INIT 02 00, packet the init packet, control INIT 02 01
//            <- 10 02 01
//   control  receipts every 10 packets       08 0a 00
//   control  RECEIVE                          03
//   packet   the image, 20 bytes at a time   <- 11 and the bytes received, every 10 packets
//            <- 10 03 01                      after the last
//   control  VALIDATE                         04  <- 10 04 01
//   control  ACTIVATE_AND_RESET               05  the bootloader starts the image
//
// The control point is written with a response and answers by notification; the packet
// characteristic is written only without one. The transport says how; the client keeps no time
// but through it, so that a test can play the bootloader.

/// A DFU package, as `adafruit-nrfutil dfu genpkg` makes it: a .zip of `manifest.json`, the init
/// packet (`.dat`) and the application (`.bin`).
public struct DFUPackage: Equatable, Sendable {
    /// What the bootloader checks the image against: its CRC, and the device it is for.
    public var initPacket: [UInt8]
    public var image: [UInt8]

    public enum ReadError: Error, Equatable {
        case zip(ZipArchive.ReadError)
        /// No `manifest.json`, or not one that names an application's `dat_file` and `bin_file`.
        case manifest
        /// The manifest names a file the package does not hold.
        case missing(String)
        /// An empty application, or one no bootloader could take: past what a u32 says.
        case badImage
    }

    public init(initPacket: [UInt8], image: [UInt8]) {
        self.initPacket = initPacket
        self.image = image
    }

    public init(zip: [UInt8]) throws {
        let archive: ZipArchive
        do { archive = try ZipArchive(zip) } catch let e as ZipArchive.ReadError { throw ReadError.zip(e) }
        func read(_ name: String) throws -> [UInt8] {
            do {
                guard let bytes = try archive.read(name) else { throw ReadError.missing(name) }
                return bytes
            } catch let e as ZipArchive.ReadError { throw ReadError.zip(e) }
        }
        guard let manifest = try? JSONValue.parse(try read("manifest.json")),
              case let .string(dat)? = manifest["manifest"]?["application"]?["dat_file"],
              case let .string(bin)? = manifest["manifest"]?["application"]?["bin_file"]
        else { throw ReadError.manifest }
        let image = try read(bin)
        guard !image.isEmpty, image.count <= Int(UInt32.max) else { throw ReadError.badImage }
        self.init(initPacket: try read(dat), image: image)
    }
}

/// The bootloader's service and characteristics.
public enum DFU {
    public static let service = "00001530-1212-EFDE-1523-785FEABCD123"
    /// Written with a response; answers by notification.
    public static let controlPoint = "00001531-1212-EFDE-1523-785FEABCD123"
    /// Written without a response only: the bootloader refuses a write with one.
    public static let packet = "00001532-1212-EFDE-1523-785FEABCD123"

    static let start: UInt8 = 0x01
    static let initialize: UInt8 = 0x02
    static let receive: UInt8 = 0x03
    static let validate: UInt8 = 0x04
    static let activate: UInt8 = 0x05
    static let reset: UInt8 = 0x06
    static let receipts: UInt8 = 0x08
    static let response: UInt8 = 0x10
    static let receipt: UInt8 = 0x11
    /// START's image type: an application, not a SoftDevice or a bootloader.
    static let application: UInt8 = 0x04

    /// A response's status.
    public static let success: UInt8 = 1
    public static let invalidState: UInt8 = 2
    public static let notSupported: UInt8 = 3
    public static let tooLarge: UInt8 = 4
    public static let crcError: UInt8 = 5
    public static let operationFailed: UInt8 = 6

    /// A packet: the least every link carries. The bootloader takes whole words only.
    public static let packetBytes = 20
    /// Packets between receipts: Nordic's own library holds legacy bootloaders to ten.
    public static let receiptEvery = 10
    /// The gap between packets of the image. A bootloader sent them faster than it writes them to
    /// flash stops with "operation failed", as the T1000-E's did; a phone's stack sends about one
    /// each connection event, which this is close to.
    public static let pace = 0.01
    /// How long START may take: the bootloader erases the application's flash page by page between
    /// the SoftDevice's radio events, tens of seconds, and on an older bootloader minutes. Given up
    /// on too soon, the bootloader is left mid-session and answers the next START "invalid state".
    public static let eraseWait = 240.0
    /// How long the init packet's answer, a receipt, and VALIDATE's answer may take.
    public static let answerWait = 10.0
    /// How long the answer to the image's last packet may take: the bootloader writes what it holds.
    public static let lastWait = 30.0
    /// How long to look for a bootloader advertising the service.
    public static let findWait = 30.0
}

/// Where a DFU is.
public enum DFUProgress: Equatable, Sendable {
    /// START sent: the bootloader is erasing the application's flash, which takes a while.
    case erasing
    case initializing
    /// `sent` of `size` bytes of the image.
    case sending(sent: Int, size: Int)
    case validating
    /// ACTIVATE sent: the bootloader starts the image.
    case activating
}

/// Why a DFU stopped. After any of these the bootloader is still waiting, over Bluetooth, for an
/// image, and keeps everything else the node held: a retry finds it again.
public enum DFUError: Error, Equatable, Sendable {
    /// The bootloader answered a step with a status other than success: `step` is the step's
    /// opcode (1 START, 2 INIT, 3 RECEIVE, 4 VALIDATE).
    case refused(step: UInt8, status: UInt8)
    /// No answer to a step, or no receipt, in the time it may take.
    case noAnswer(step: UInt8)
    /// The bootloader was left part of the way through an earlier session, and was told to
    /// restart: it advertises again in a moment, ready for a new one.
    case wasMidSession
    /// The link to the bootloader failed or went.
    case lost
    case cancelled
}

/// What a DFU client speaks through: the bootloader's control point and packet characteristic,
/// once connected and subscribed to the control point's notifications.
public protocol DFUTransport: AnyObject {
    /// Writes the control point, with a response. Throws if the write fails.
    func writeControl(_ bytes: [UInt8]) async throws
    /// Writes the packet characteristic, without a response, once the link can take it.
    func writePacket(_ bytes: [UInt8]) async throws
    /// The control point's next notification, in the order they came; nil if none comes within
    /// `seconds`. Notifications that came before this was called are kept for it.
    func notification(within seconds: Double) async throws -> [UInt8]?
    /// Waits `seconds`: the gap between packets.
    func pause(_ seconds: Double) async throws
}

/// Sends a DFU package to a bootloader, as the comment at the top says.
public final class DFUClient {
    public let package: DFUPackage
    /// Called as each step begins, and as the image goes, each time its whole percent changes.
    public var onProgress: (DFUProgress) -> Void = { _ in }

    public init(package: DFUPackage) {
        self.package = package
    }

    /// Runs the whole DFU over `transport`. Returns once ACTIVATE is written, or the link drops as
    /// it is: the bootloader resets into the image as it answers. Runs on the caller's actor, as
    /// `onProgress` is called.
    public func run(_ transport: DFUTransport, isolation: isolated (any Actor)? = #isolation) async throws {
        let image = package.image
        do {
            onProgress(.erasing)
            try await transport.writeControl([DFU.start, DFU.application])
            try await transport.writePacket(Self.le32(0) + Self.le32(0) + Self.le32(UInt32(image.count)))
            do {
                try await answer(DFU.start, transport, within: DFU.eraseWait)
            } catch DFUError.refused(DFU.start, DFU.invalidState) {
                // An earlier session that was given up on part of the way: the bootloader takes no
                // new one until it restarts, and it advertises again once it has.
                try? await transport.writeControl([DFU.reset])
                throw DFUError.wasMidSession
            }

            onProgress(.initializing)
            try await transport.writeControl([DFU.initialize, 0x00])
            for at in stride(from: 0, to: package.initPacket.count, by: DFU.packetBytes) {
                try await transport.writePacket(Array(package.initPacket[at..<min(at + DFU.packetBytes, package.initPacket.count)]))
            }
            try await transport.writeControl([DFU.initialize, 0x01])
            try await answer(DFU.initialize, transport, within: DFU.answerWait)

            try await transport.writeControl([DFU.receipts, UInt8(DFU.receiptEvery), 0x00])
            try await transport.writeControl([DFU.receive])
            var shown = -1
            var packets = 0
            for at in stride(from: 0, to: image.count, by: DFU.packetBytes) {
                if Task.isCancelled { throw DFUError.cancelled }
                let end = min(at + DFU.packetBytes, image.count)
                try await transport.writePacket(Array(image[at..<end]))
                try await transport.pause(DFU.pace)
                packets += 1
                // The receipt is the flow control: nothing more until it comes. None follows the
                // last packet, which the step's own answer does.
                if packets % DFU.receiptEvery == 0, end < image.count {
                    try await receipt(transport)
                }
                let percent = end * 100 / image.count
                if percent != shown {
                    shown = percent
                    onProgress(.sending(sent: end, size: image.count))
                }
            }
            try await answer(DFU.receive, transport, within: DFU.lastWait)

            onProgress(.validating)
            try await transport.writeControl([DFU.validate])
            try await answer(DFU.validate, transport, within: DFU.answerWait)
        } catch let e as DFUError {
            throw e
        } catch is CancellationError {
            throw DFUError.cancelled
        } catch {
            throw DFUError.lost
        }

        onProgress(.activating)
        // The bootloader resets into the image as it answers, and the link may drop before the
        // write is acknowledged: that is success.
        try? await transport.writeControl([DFU.activate])
    }

    /// Waits for the response to `step`, passing over a late receipt.
    private func answer(_ step: UInt8, _ transport: DFUTransport, within seconds: Double) async throws {
        while true {
            guard let n = try await transport.notification(within: seconds) else { throw DFUError.noAnswer(step: step) }
            guard n.count >= 3, n[0] == DFU.response, n[1] == step else { continue }
            guard n[2] == DFU.success else { throw DFUError.refused(step: step, status: n[2]) }
            return
        }
    }

    /// Waits for a receipt. A response in its place is the bootloader stopping the transfer.
    private func receipt(_ transport: DFUTransport) async throws {
        while true {
            guard let n = try await transport.notification(within: DFU.answerWait) else {
                throw DFUError.noAnswer(step: DFU.receipt)
            }
            if n.first == DFU.receipt { return }
            if n.count >= 3, n[0] == DFU.response, n[2] != DFU.success {
                throw DFUError.refused(step: n[1], status: n[2])
            }
        }
    }

    private static func le32(_ n: UInt32) -> [UInt8] {
        [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)]
    }
}
