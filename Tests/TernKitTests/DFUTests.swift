// The DFU package, read from real ones, and the legacy DFU client against a bootloader played by
// hand.
//
// fixtures/dfu-stored.zip is what `adafruit-nrfutil dfu genpkg --dev-type 0x0052 --sd-req 0xFFFE
// --application app.hex` makes of fixtures/app.hex, 600 bytes at 0x26000: its entries stored.
// fixtures/dfu-deflated.zip holds the same three files deflated, as Python's zipfile writes them:
// manifest.json in a block with its own Huffman codes, the others with the fixed codes.

import Foundation
import XCTest

@testable import TernKit

final class DFUTests: XCTestCase {
    static func fixture(_ name: String) -> [UInt8] {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "fixtures")!
        return [UInt8](try! Data(contentsOf: url))
    }

    /// The application genpkg packed: SHA-256 of the 600 bytes app.hex holds.
    static let imageDigest = "4d2f67efef47bb729a4a2c3924d1fd2a3e3de8cc5279ba6b75c25e60b54bac2d"

    // MARK: The package

    func testAPackageGenpkgMade() throws {
        let p = try DFUPackage(zip: Self.fixture("dfu-stored.zip"))
        XCTAssertEqual(p.image.count, 600)
        XCTAssertEqual(SHA256.hash(p.image).description, Self.imageDigest)
        XCTAssertEqual(p.initPacket.count, 14)
        // The init packet: device type 0x0052, revision 0xFFFF, version 0xFFFFFFFF, one SoftDevice
        // 0xFFFE, then the image's CRC-16, 28512 as the manifest says.
        XCTAssertEqual(Array(p.initPacket.prefix(2)), [0x52, 0x00])
        XCTAssertEqual(Int(p.initPacket[12]) | Int(p.initPacket[13]) << 8, 28512)
    }

    func testTheSamePackageDeflated() throws {
        let stored = try DFUPackage(zip: Self.fixture("dfu-stored.zip"))
        XCTAssertEqual(try DFUPackage(zip: Self.fixture("dfu-deflated.zip")), stored)
        let zip = try ZipArchive(Self.fixture("dfu-deflated.zip"))
        XCTAssertEqual(zip.names, ["app.bin", "app.dat", "manifest.json"])
        let manifest = try XCTUnwrap(zip.read("manifest.json"))
        XCTAssertEqual(manifest.count, 457)
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains("\"dfu_version\": 0.5"))
        XCTAssertNil(try zip.read("absent"))
    }

    func testAPackageThatIsNotOne() throws {
        func error(_ bytes: [UInt8]) -> DFUPackage.ReadError? {
            do {
                _ = try DFUPackage(zip: bytes)
                return nil
            } catch {
                return error as? DFUPackage.ReadError
            }
        }
        XCTAssertEqual(error([]), .zip(.notZip))
        XCTAssertEqual(error(Array("not a zip at all, but long enough to look".utf8)), .zip(.notZip))
        // A byte of the application changed: its CRC-32 is not the entry's.
        var stored = Self.fixture("dfu-stored.zip")
        let at = try XCTUnwrap(Self.find(Array("app.bin".utf8), in: stored)) + 7 + 100
        stored[at] ^= 0xFF
        XCTAssertEqual(error(stored), .zip(.damaged("app.bin")))
        // Deflated bytes changed: they do not inflate to the entry, or not with its CRC-32.
        var deflated = Self.fixture("dfu-deflated.zip")
        let at2 = try XCTUnwrap(Self.find(Array("app.bin".utf8), in: deflated)) + 7 + 50
        deflated[at2] ^= 0xFF
        XCTAssertEqual(error(deflated), .zip(.damaged("app.bin")))
    }

    func testRawDeflate() throws {
        // zlib's level 0, a stored block; and its fixed Huffman codes, with back references that
        // overlap what they copy.
        XCTAssertEqual(try Inflate.run(Hex.decode("010d00f2ff5465726e2c2073746f7265642e")![...], limit: 100), Array("Tern, stored.".utf8))
        XCTAssertEqual(try Inflate.run(Hex.decode("2b492dca5328c1241401")![...], limit: 100), Array("tern tern tern tern tern!".utf8))
        // No more than the entry says it holds.
        XCTAssertThrowsError(try Inflate.run(Hex.decode("2b492dca5328c1241401")![...], limit: 10))
        XCTAssertThrowsError(try Inflate.run(Hex.decode("2b492d")![...], limit: 100), "cut short")
        XCTAssertEqual(CRC32.of(Array("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: The client

    func testTheWholeExchange() async throws {
        let package = try DFUPackage(zip: Self.fixture("dfu-stored.zip"))
        let boot = FakeBootloader()
        let client = DFUClient(package: package)
        var progress: [DFUProgress] = []
        client.onProgress = { progress.append($0) }
        try await client.run(boot)

        XCTAssertEqual(boot.controls, [[1, 4], [2, 0], [2, 1], [8, 10, 0], [3], [4], [5]])
        XCTAssertEqual(boot.sizes, [0, 0, 0, 0, 0, 0, 0, 0, 0x58, 0x02, 0, 0], "no SoftDevice, no bootloader, 600 bytes")
        XCTAssertEqual(boot.initPacket, package.initPacket)
        XCTAssertEqual(boot.image, package.image)
        XCTAssertTrue(boot.packets.allSatisfy { $0.count <= DFU.packetBytes })
        XCTAssertEqual(boot.packets.count, 1 + 1 + 30, "the sizes, the init packet, and the image in 20-byte packets")
        XCTAssertEqual(boot.pauses, 30, "a pause after each packet of the image")
        XCTAssertEqual(boot.waits.first, DFU.eraseWait, "the erase may take minutes")
        XCTAssertFalse(boot.overrun)
        XCTAssertTrue(boot.activated)

        XCTAssertEqual(progress.first, .erasing)
        XCTAssertEqual(progress.dropFirst().first, .initializing)
        XCTAssertEqual(Array(progress.suffix(2)), [.validating, .activating])
        let sent = progress.compactMap { if case let .sending(s, size) = $0 { s * 100 / size } else { nil } }
        XCTAssertEqual(sent.first, 3)
        XCTAssertEqual(sent.last, 100)
        XCTAssertEqual(sent, sent.sorted())
    }

    /// After every tenth packet but the last, nothing goes until the receipt has come.
    func testTheReceiptIsTheFlowControl() async throws {
        let boot = FakeBootloader()
        boot.receiptsHeld = true
        let image = [UInt8](repeating: 0xA5, count: 20 * 25 + 4)
        try await DFUClient(package: DFUPackage(initPacket: [1, 2, 3], image: image)).run(boot)
        XCTAssertFalse(boot.overrun)
        XCTAssertEqual(boot.receiptsTaken, 2, "after the 10th and 20th of 26 packets")
        XCTAssertEqual(boot.image, image)
        XCTAssertEqual(boot.packets.last?.count, 4, "the last packet is what is left")
    }

    func testAReceiptThatNeverComes() async throws {
        let boot = FakeBootloader()
        boot.dropReceipts = true
        let client = DFUClient(package: DFUPackage(initPacket: [1], image: [UInt8](repeating: 1, count: 1000)))
        do {
            try await client.run(boot)
            XCTFail("finished without its receipts")
        } catch let e as DFUError {
            XCTAssertEqual(e, .noAnswer(step: 0x11))
        }
        XCTAssertEqual(boot.image.count, 200, "nothing after the tenth packet")
        XCTAssertEqual(boot.waits.last, DFU.answerWait)
        XCTAssertFalse(boot.activated)
        XCTAssertTrue(Words.bootloader(.failed(.noAnswer(step: 0x11))).contains("waiting in its bootloader"))
    }

    func testARefusedStep() async throws {
        for (step, status) in [(UInt8(1), DFU.tooLarge), (2, DFU.crcError), (3, DFU.operationFailed), (4, DFU.crcError)] {
            let boot = FakeBootloader()
            boot.refuse = [step: status]
            do {
                try await DFUClient(package: DFUPackage(initPacket: [1, 2], image: [UInt8](repeating: 7, count: 300))).run(boot)
                XCTFail("step \(step) was refused")
            } catch let e as DFUError {
                XCTAssertEqual(e, .refused(step: step, status: status))
            }
            XCTAssertFalse(boot.activated)
            XCTAssertEqual(boot.controls.last?.first, step == 3 ? 3 : step, "nothing after the step refused")
        }
    }

    /// The bootloader stopping part of the way through the image answers in place of a receipt.
    func testStoppedPartOfTheWay() async throws {
        let boot = FakeBootloader()
        boot.stopAfter = 15
        do {
            try await DFUClient(package: DFUPackage(initPacket: [1], image: [UInt8](repeating: 7, count: 1000))).run(boot)
            XCTFail()
        } catch let e as DFUError {
            XCTAssertEqual(e, .refused(step: 3, status: DFU.operationFailed))
        }
        XCTAssertEqual(boot.packets.count - 2, 20)
    }

    /// A bootloader left part of the way through a session is told to restart.
    func testABootloaderMidSession() async throws {
        let boot = FakeBootloader()
        boot.refuse = [1: DFU.invalidState]
        do {
            try await DFUClient(package: DFUPackage(initPacket: [1], image: [1, 2, 3, 4])).run(boot)
            XCTFail()
        } catch let e as DFUError {
            XCTAssertEqual(e, .wasMidSession)
        }
        XCTAssertEqual(boot.controls, [[1, 4], [6]])
    }

    func testNoAnswerToTheErase() async throws {
        let boot = FakeBootloader()
        boot.silentAt = 1
        do {
            try await DFUClient(package: DFUPackage(initPacket: [1], image: [1, 2, 3, 4])).run(boot)
            XCTFail()
        } catch let e as DFUError {
            XCTAssertEqual(e, .noAnswer(step: 1))
        }
        XCTAssertEqual(boot.waits, [DFU.eraseWait])
    }

    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        return (0...(hay.count - needle.count)).first { Array(hay[$0..<$0 + needle.count]) == needle }
    }
}

/// A bootloader played by hand: it answers each step as Adafruit's does, sends a receipt after
/// every tenth packet of the image, and notes what it was sent.
final class FakeBootloader: DFUTransport {
    /// Steps answered with a status other than success.
    var refuse: [UInt8: UInt8] = [:]
    /// The step whose answer never comes.
    var silentAt: UInt8?
    /// Receipts are never sent.
    var dropReceipts = false
    /// Receipts are sent, but only once asked for: the client must wait for each.
    var receiptsHeld = false
    /// After this many packets of the image, the bootloader stops with "operation failed".
    var stopAfter: Int?

    private(set) var controls: [[UInt8]] = []
    private(set) var packets: [[UInt8]] = []
    private(set) var sizes: [UInt8] = []
    private(set) var initPacket: [UInt8] = []
    private(set) var image: [UInt8] = []
    private(set) var waits: [Double] = []
    private(set) var pauses = 0
    private(set) var activated = false
    private(set) var receiptsTaken = 0
    /// A packet of the image came while a receipt was owed and not yet taken.
    private(set) var overrun = false

    private enum Stage { case idle, sizes, initPacket, receiving, done }
    private var stage = Stage.idle
    private var expected = 0
    private var every = 0
    private var imagePackets = 0
    private var sinceReceipt = 0
    private var notifications: [[UInt8]] = []
    private var heldReceipt: [UInt8]?

    func writeControl(_ bytes: [UInt8]) async throws {
        controls.append(bytes)
        switch bytes[0] {
        case 0x01: stage = .sizes
        case 0x02:
            if bytes[1] == 0 { stage = .initPacket } else { stage = .idle; respond(2) }
        case 0x08: every = Int(bytes[1])
        case 0x03: stage = .receiving
        case 0x04: respond(4)
        case 0x05: activated = true
        default: break
        }
    }

    func writePacket(_ bytes: [UInt8]) async throws {
        packets.append(bytes)
        switch stage {
        case .sizes:
            sizes = bytes
            expected = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
            stage = .idle
            respond(1)
        case .initPacket:
            initPacket += bytes
        case .receiving:
            if sinceReceipt >= every { overrun = true }
            image += bytes
            imagePackets += 1
            sinceReceipt += 1
            if let stopAfter, imagePackets == stopAfter {
                stage = .done
                return notifications.append([0x10, 3, DFU.operationFailed])
            }
            if imagePackets % every == 0, !dropReceipts {
                let n = image.count
                let receipt: [UInt8] = [0x11, UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)]
                if receiptsHeld { heldReceipt = receipt } else { notifications.append(receipt) }
            }
            if image.count >= expected {
                stage = .done
                respond(3)
            }
        case .idle, .done:
            break
        }
    }

    func notification(within seconds: Double) async throws -> [UInt8]? {
        waits.append(seconds)
        if let r = heldReceipt {
            heldReceipt = nil
            notifications.insert(r, at: 0)
        }
        guard !notifications.isEmpty else { return nil }
        let n = notifications.removeFirst()
        if n[0] == 0x11 {
            receiptsTaken += 1
            sinceReceipt = 0
        }
        return n
    }

    func pause(_ seconds: Double) async throws {
        XCTAssertEqual(seconds, DFU.pace)
        pauses += 1
    }

    private func respond(_ step: UInt8) {
        if silentAt == step { return }
        notifications.append([0x10, step, refuse[step] ?? DFU.success])
    }
}
