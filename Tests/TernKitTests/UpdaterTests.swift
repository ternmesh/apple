// The updater, as the client in the specification's `update` vectors, and how it recovers against a
// node played by hand: the update not where it was sent, an answer lost, UPDATE_END never sent twice.

import XCTest

@testable import TernKit

final class UpdaterTests: XCTestCase {
    var v: [String: JSON] { CompanionVectorTests.vectors }
    var image: [UInt8] { v["image"]!.bytes }

    // MARK: The specification's update, from the client's side

    func testTheImagesDigest() {
        XCTAssertEqual(SHA256.hash(image).description, v["image_digest"]!.string)
        XCTAssertEqual(Updater(image: image).digest.description, v["image_digest"]!.string)
    }

    /// The client sends both connections' frames byte for byte: the first until its link is lost,
    /// and the second going on from the offset the node gives, to `UPDATE_END`.
    func testUpdateOverTwoConnections() throws {
        let connections = v["update"]!.array.map(\.array)
        XCTAssertEqual(connections.count, 2)
        let setTime = try XCTUnwrap(connections[0].first { $0["type"]!.string == "SET_TIME" })
        guard case let .setTime(time) = try Frame.decode(setTime["frame"]!.bytes).body else { return XCTFail() }

        let updater = Updater(image: image)
        var progress: [Int] = []
        updater.onChange = { if progress.last != updater.held { progress.append(updater.held) } }

        // The first: the updater starts as the connection opens, and its BEGIN waits for the sync.
        let wire = Wire()
        let first = Connection(now: { 0 }, wallTime: { time })
        first.send = { wire.out.append($0) }
        first.open()
        updater.resume(on: first)
        play(connections[0], on: first, wire)
        // The DATA after the last frame went as the link was lost.
        XCTAssertEqual(try wire.out.map { try Frame.decode($0).body.name }, ["UPDATE_DATA"])
        wire.out = []
        first.close()
        XCTAssertEqual(updater.phase, .waiting)
        XCTAssertEqual(updater.held, 344)

        // The second, on a connection made afresh with what the first held: the app goes on once
        // the node has answered HELLO.
        let second = Connection(records: first.records, now: { 0 }, wallTime: { time })
        second.send = { wire.out.append($0) }
        second.onEvent = { if case .ready = $0 { updater.resume(on: second) } }
        second.open()
        XCTAssertEqual(updater.phase, .waiting, "nothing until the node answers")
        play(connections[1], on: second, wire)
        XCTAssertEqual(wire.out, [])
        XCTAssertEqual(updater.phase, .finished(.restarting))
        XCTAssertEqual(second.board, "heltec-v3")
        XCTAssertEqual(second.release, "0.2.0")
        XCTAssertEqual(progress, [0, 172, 344, 400])
    }

    /// The node's frames in `refusals` read and build back, and each refusal is the code the
    /// vector gives.
    func testRefusalsReadAndBuildBack() throws {
        var codes: [UInt8] = []
        for f in v["refusals"]!.array {
            let frame = try Frame.decode(f["frame"]!.bytes)
            XCTAssertEqual(frame.body.name, f["type"]!.string)
            XCTAssertEqual(Int(frame.seq), f["seq"]!.int)
            XCTAssertEqual(Hex.encode(try frame.encode()), f["frame"]!.string)
            if case let .error(code) = frame.body { codes.append(code) }
        }
        // The last: `UPDATE_BOOTLOADER`, to a node updated over the link, not by its bootloader.
        XCTAssertEqual(codes, [10, 10, 3, 10, 3, 3, 10, 11, 10, 5])
    }

    // MARK: Against a node played by hand

    func testItSendsChunksOfUpdateChunkBytesThenEnds() throws {
        let node = UpdateNode()
        let updater = Updater(image: [UInt8](repeating: 9, count: 400))
        updater.resume(on: node)
        XCTAssertEqual(node.take(), .updateBegin(size: 400, digest: updater.digest))
        node.answer(.success(.updating(offset: 0)))
        for (offset, n) in [(0, 172), (172, 172), (344, 56)] {
            guard case let .updateData(o, data) = node.take() else { return XCTFail() }
            XCTAssertEqual(Int(o), offset)
            XCTAssertEqual(data.count, n)
            node.answer(.success(.ok))
        }
        XCTAssertEqual(node.take(), .updateEnd)
        XCTAssertEqual(updater.phase, .ending)
        node.answer(.success(.ok))
        XCTAssertEqual(updater.phase, .finished(.restarting))
        XCTAssertEqual(node.asked, [])
    }

    /// ERROR 10 to a DATA: BEGIN again, and go on from where the node says.
    func testNotWhereTheUpdateIsBeginsAgain() throws {
        let node = UpdateNode()
        let updater = Updater(image: [UInt8](repeating: 9, count: 400))
        updater.resume(on: node)
        _ = node.take()
        node.answer(.success(.updating(offset: 172)))
        XCTAssertEqual(node.takeOffset(), 172)
        node.answer(.failure(.refused(code: ErrorCode.notThere)))
        XCTAssertEqual(node.take(), .updateBegin(size: 400, digest: updater.digest))
        node.answer(.success(.updating(offset: 0)))
        XCTAssertEqual(node.takeOffset(), 0)
        node.answer(.success(.ok))
        XCTAssertEqual(node.takeOffset(), 172)
        XCTAssertEqual(updater.held, 172)
    }

    /// ERROR 10 to END: the node holds less than the image. BEGIN again; END is sent again only
    /// once the node has the rest.
    func testEndNotWhereTheUpdateIsBeginsAgain() throws {
        let node = UpdateNode()
        let updater = Updater(image: [UInt8](repeating: 9, count: 10))
        updater.resume(on: node)
        _ = node.take()
        node.answer(.success(.updating(offset: 10)))
        XCTAssertEqual(node.take(), .updateEnd)
        node.answer(.failure(.refused(code: ErrorCode.notThere)))
        XCTAssertEqual(node.take(), .updateBegin(size: 10, digest: updater.digest))
        node.answer(.success(.updating(offset: 0)))
        XCTAssertEqual(node.takeOffset(), 0)
        node.answer(.success(.ok))
        XCTAssertEqual(node.take(), .updateEnd)
        node.answer(.success(.ok))
        XCTAssertEqual(updater.phase, .finished(.restarting))
    }

    /// A node that keeps saying the update is elsewhere is not asked for ever.
    func testNotWhereTheUpdateIsAgainAndAgainGivesUp() throws {
        let node = UpdateNode()
        let updater = Updater(image: [UInt8](repeating: 9, count: 400))
        updater.resume(on: node)
        for _ in 0..<Updater.triesNotThere {
            _ = node.take()  // BEGIN
            node.answer(.success(.updating(offset: 0)))
            _ = node.take()  // DATA
            node.answer(.failure(.refused(code: ErrorCode.notThere)))
        }
        XCTAssertEqual(updater.phase, .finished(.refused(code: ErrorCode.notThere)))
        XCTAssertEqual(node.asked, [])
    }

    /// The answer to a DATA lost: the same chunk goes again, at the same offset.
    func testALostAnswerSendsTheSameChunkAgain() throws {
        let node = UpdateNode()
        let updater = Updater(image: Array(0..<255) + Array(0..<145))
        updater.resume(on: node)
        _ = node.take()
        node.answer(.success(.updating(offset: 0)))
        let first = node.take()
        node.answer(.failure(.noAnswer))
        XCTAssertEqual(node.take(), first)
        node.answer(.success(.ok))
        XCTAssertEqual(node.takeOffset(), 172)
    }

    /// Over a Connection, a lost answer closes it: the chunk cannot go again there, and the
    /// updater waits, then BEGINs again on the connection that opens.
    func testALostAnswerOnAConnectionWaitsForItToOpenAgain() throws {
        var time = 0.0
        let wire = Wire()
        let c = Connection(now: { time }, wallTime: nil)
        c.send = { wire.out.append($0) }
        c.open()
        answer(c, wire, .info(version: 4, firmware: "t", board: "b", release: "1.0.0"))
        answer(c, wire, .synced(news: 0))
        let updater = Updater(image: [UInt8](repeating: 1, count: 300))
        updater.resume(on: c)
        answer(c, wire, .updating(offset: 0))
        XCTAssertEqual(try Frame.decode(wire.out[0]).body.name, "UPDATE_DATA")
        time += Companion.answerWait
        c.tick()
        XCTAssertEqual(updater.phase, .waiting)
        XCTAssertEqual(updater.held, 0)

        wire.out = []
        c.open()
        updater.resume(on: c)
        answer(c, wire, .info(version: 4, firmware: "t", board: "b", release: "1.0.0"))
        answer(c, wire, .synced(news: 0))
        XCTAssertEqual(try Frame.decode(wire.out[0]).body, .updateBegin(size: 300, digest: updater.digest))
    }

    /// END given up on is not sent again: the node may be restarting into the image.
    func testEndIsNeverSentAgain() throws {
        for failure in [RequestFailure.noAnswer, .closed] {
            let node = UpdateNode()
            let updater = Updater(image: [1, 2, 3])
            updater.resume(on: node)
            _ = node.take()
            node.answer(.success(.updating(offset: 3)))
            XCTAssertEqual(node.take(), .updateEnd)
            XCTAssertFalse(updater.cancel(), "too late to cancel")
            node.answer(.failure(failure))
            XCTAssertEqual(updater.phase, .finished(.unconfirmed))
            XCTAssertEqual(node.asked, [])
            updater.resume(on: node)
            XCTAssertEqual(node.asked, [], "nor on a connection that opens again")
        }
    }

    /// An image the node does not run is refused at the end, and the update is over.
    func testNotAnImageThisNodeRuns() throws {
        let refusals = v["refusals"]!.array
        let begin = try XCTUnwrap(refusals.last { $0["type"]!.string == "UPDATE_BEGIN" })
        guard case let .updateBegin(_, wrong) = try Frame.decode(begin["frame"]!.bytes).body else { return XCTFail() }

        let node = UpdateNode()
        let updater = Updater(image: image, digest: wrong)
        updater.resume(on: node)
        XCTAssertEqual(try Frame(seq: 5, body: XCTUnwrap(node.take())).encode(), begin["frame"]!.bytes)
        node.answer(.success(.updating(offset: 0)))
        for _ in 0..<3 {
            _ = node.take()
            node.answer(.success(.ok))
        }
        XCTAssertEqual(node.take(), .updateEnd)
        node.answer(.failure(.refused(code: ErrorCode.notAnImage)))
        XCTAssertEqual(updater.phase, .finished(.refused(code: ErrorCode.notAnImage)))
        XCTAssertEqual(Words.update(.refused(code: ErrorCode.notAnImage)).contains("not firmware this node runs"), true)
    }

    /// A node with no board, or no room, answers BEGIN with 5: it cannot be updated this way.
    func testNoRoomIsTheUSBHint() throws {
        let node = UpdateNode()
        let updater = Updater(image: [1])
        updater.resume(on: node)
        _ = node.take()
        node.answer(.failure(.refused(code: ErrorCode.noRoom)))
        XCTAssertEqual(updater.phase, .finished(.refused(code: ErrorCode.noRoom)))
        XCTAssertTrue(Words.update(.refused(code: ErrorCode.noRoom)).contains("ternmesh.org/flash"))
    }

    /// A node of version 3 is not asked: the connection says so, and so does the updater.
    func testANodeOfVersion3() throws {
        let wire = Wire()
        let c = Connection(now: { 0 }, wallTime: nil)
        c.send = { wire.out.append($0) }
        c.open()
        answer(c, wire, .info(version: 3, firmware: "t", board: nil, release: nil))
        answer(c, wire, .synced(news: 0))
        let updater = Updater(image: [1])
        updater.resume(on: c)
        XCTAssertEqual(updater.phase, .finished(.unsupported))
        XCTAssertEqual(wire.out, [])
        XCTAssertNil(c.board)
    }

    func testCancelStopsOnceTheRequestOutIsAnswered() throws {
        let node = UpdateNode()
        let updater = Updater(image: [UInt8](repeating: 9, count: 400))
        updater.resume(on: node)
        _ = node.take()
        node.answer(.success(.updating(offset: 0)))
        _ = node.take()
        XCTAssertTrue(updater.cancel())
        XCTAssertEqual(updater.phase, .sending)
        node.answer(.success(.ok))
        XCTAssertEqual(updater.phase, .finished(.cancelled))
        XCTAssertEqual(updater.held, 172)
        XCTAssertEqual(node.asked, [])

        let waiting = Updater(image: [1])
        let gone = UpdateNode()
        waiting.resume(on: gone)
        gone.answer(.failure(.closed))
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertTrue(waiting.cancel())
        XCTAssertEqual(waiting.phase, .finished(.cancelled))
    }

    /// An answer to a request made before the updater resumed elsewhere is ignored.
    func testAnAnswerFromBeforeIsIgnored() throws {
        let old = UpdateNode()
        let updater = Updater(image: [UInt8](repeating: 9, count: 400))
        updater.resume(on: old)
        _ = old.take()
        old.answer(.success(.updating(offset: 0)))
        _ = old.take()
        let late = old.pending!
        old.answer(.failure(.closed))
        let new = UpdateNode()
        updater.resume(on: new)
        late(.success(.ok))
        XCTAssertEqual(updater.held, 0)
        XCTAssertEqual(new.take(), .updateBegin(size: 400, digest: updater.digest))
    }

    // MARK: By the bootloader

    func package() -> DFUPackage { DFUPackage(initPacket: [1, 2, 3], image: [UInt8](repeating: 0x5A, count: 250)) }

    /// Asked, the node answers `OK` and restarts; the bootloader is found by its service and given
    /// the package; it starts the image.
    func testByTheBootloader() async throws {
        let node = UpdateNode()
        let finder = FakeFinder()
        let updater = BootloaderUpdater(package: package())
        var phases: [BootloaderUpdater.Phase] = []
        updater.onChange = { if phases.last != updater.phase { phases.append(updater.phase) } }
        node.onSubmit = { node.answer(.success(.ok)) }
        let outcome = await updater.run(asking: node, finder: finder)

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(node.asked, [.updateBootloader])
        XCTAssertEqual(finder.looked, [DFU.findWait])
        XCTAssertEqual(finder.released, 1)
        let boot = try XCTUnwrap(finder.bootloaders.first)
        XCTAssertEqual(boot.image, package().image)
        XCTAssertTrue(boot.activated)
        XCTAssertFalse(updater.inBootloader, "the image is activated: the node comes back as itself")
        XCTAssertEqual(Array(phases.prefix(4)), [.asking, .looking, .transferring(.erasing), .transferring(.initializing)])
        XCTAssertEqual(phases.last, .finished(.activated))
        XCTAssertTrue(phases.contains(.transferring(.sending(sent: 250, size: 250))))
        XCTAssertEqual(Words.bootloader(.transferring(.sending(sent: 125, size: 250))), "Sending: 50%")
    }

    /// The node over the vectors' first bootloader connection: refused an update over the link,
    /// and answered `UPDATE_BOOTLOADER`; the updater asks it through the connection, byte for byte.
    @MainActor
    func testTheVectorsBootloaderConnection() async throws {
        let frames = v["bootloader"]!.array[0].array
        let wire = Wire()
        let c = Connection(now: { 0 }, wallTime: { 1_790_000_000 })
        c.send = { wire.out.append($0) }
        c.open()
        XCTAssertEqual(Hex.encode(wire.out.removeFirst()), frames[0]["frame"]!.string)
        c.receive(frames[1]["frame"]!.bytes)
        answer(c, wire, .ok)
        answer(c, wire, .synced(news: 0))
        XCTAssertEqual(c.updateMethod, .bootloader)
        // Over the link first, as an app of version 11 would: refused, as the vector has it.
        var begun: Result<Body, RequestFailure>?
        c.submit(try Frame.decode(frames[2]["frame"]!.bytes).body) { begun = $0 }
        XCTAssertEqual(Hex.encode(wire.out.removeFirst()), frames[2]["frame"]!.string)
        c.receive(frames[3]["frame"]!.bytes)
        XCTAssertEqual(begun, .failure(.refused(code: ErrorCode.noRoom)))

        let finder = FakeFinder()
        let updater = BootloaderUpdater(package: package())
        let task = Task { await updater.run(asking: c, finder: finder) }
        while wire.out.isEmpty { await Task.yield() }
        XCTAssertEqual(Hex.encode(wire.out.removeFirst()), frames[4]["frame"]!.string)
        c.receive(frames[5]["frame"]!.bytes)
        let outcome = await task.value
        XCTAssertEqual(outcome, .activated)
    }

    /// Refused, the node is not restarting: nothing is looked for.
    func testRefusedByANodeNotUpdatedThatWay() async throws {
        let node = UpdateNode()
        node.onSubmit = { node.answer(.failure(.refused(code: ErrorCode.noRoom))) }
        let finder = FakeFinder()
        let updater = BootloaderUpdater(package: package())
        let refused = await updater.run(asking: node, finder: finder)
        XCTAssertEqual(refused, .refused(code: ErrorCode.noRoom))
        XCTAssertEqual(finder.looked, [])
        XCTAssertFalse(updater.inBootloader)
        XCTAssertTrue(Words.bootloader(.refused(code: ErrorCode.noRoom)).contains("ternmesh.org/flash"))

        let older = UpdateNode()
        older.onSubmit = { older.answer(.failure(.unsupported)) }
        let unsupported = await BootloaderUpdater(package: package()).run(asking: older, finder: finder)
        XCTAssertEqual(unsupported, .unsupported)
    }

    /// Unanswered, `UPDATE_BOOTLOADER` is not sent again: the node may be restarting, and the
    /// bootloader is looked for.
    func testUnansweredItLooksForTheBootloader() async throws {
        for failure in [RequestFailure.noAnswer, .closed] {
            let node = UpdateNode()
            node.onSubmit = { node.answer(.failure(failure)) }
            let finder = FakeFinder()
            let updater = BootloaderUpdater(package: package())
            let ended = await updater.run(asking: node, finder: finder)
            XCTAssertEqual(ended, .activated)
            XCTAssertEqual(node.asked, [.updateBootloader])
            XCTAssertEqual(finder.looked.count, 1)
        }
    }

    /// No bootloader found; and one that fails part of the way, which leaves it waiting, so that
    /// an update started again without the node goes straight to it.
    func testNotFoundAndFailedAndAgain() async throws {
        let node = UpdateNode()
        node.onSubmit = { node.answer(.success(.ok)) }
        let none = FakeFinder()
        none.found = false
        let lost = BootloaderUpdater(package: package())
        let notFound = await lost.run(asking: node, finder: none)
        XCTAssertEqual(notFound, .notFound)
        XCTAssertTrue(lost.inBootloader)
        XCTAssertTrue(Words.bootloader(.notFound).contains("not found"))

        let failing = FakeFinder()
        failing.configure = { $0.dropReceipts = true }
        let updater = BootloaderUpdater(package: package())
        let outcome = await updater.run(asking: UpdateNode.answering(.success(.ok)), finder: failing)
        XCTAssertEqual(outcome, .failed(.noAnswer(step: 0x11)))
        XCTAssertTrue(updater.inBootloader)
        XCTAssertEqual(failing.released, 1, "the bootloader let go of, to be found again")
        XCTAssertTrue(Words.bootloader(outcome).contains("waiting in its bootloader"))

        let again = BootloaderUpdater(package: package())
        let finder = FakeFinder()
        let resumed = await again.run(asking: nil, finder: finder)
        XCTAssertEqual(resumed, .activated, "without the node, which is not there")
        XCTAssertEqual(finder.looked.count, 1)
    }

    /// A bootloader left mid-session is told to restart, and is found and started again; once.
    func testABootloaderMidSessionIsStartedAgainOnce() async throws {
        let finder = FakeFinder()
        var first = true
        finder.configure = { boot in
            if first { boot.refuse = [1: DFU.invalidState] }
            first = false
        }
        let restarted = await BootloaderUpdater(package: package()).run(asking: nil, finder: finder)
        XCTAssertEqual(restarted, .activated)
        XCTAssertEqual(finder.looked.count, 2)
        XCTAssertEqual(finder.bootloaders[0].controls, [[1, 4], [6]])

        let stuck = FakeFinder()
        stuck.configure = { $0.refuse = [1: DFU.invalidState] }
        let stuckOutcome = await BootloaderUpdater(package: package()).run(asking: nil, finder: stuck)
        XCTAssertEqual(stuckOutcome, .failed(.wasMidSession))
        XCTAssertEqual(stuck.looked.count, 2)
    }

    /// The manifest's image for each way a node is updated: the link's for a board alone, or
    /// `update` 1; the bootloader's DFU package for `update` 2; none for 0.
    func testTheImageForTheWayTheNodeIsUpdated() throws {
        let digest = String(repeating: "ab", count: 32)
        let json = #"""
            {"release":"0.6.0","images":[
             {"board":"heltec-v3","region":"US915","file":"tern-heltec-v3-us915-0.6.0-app.bin","size":10,"sha256":"\#(digest)"},
             {"board":"heltec-t114","region":"US915","file":"tern-heltec-t114-us915-0.6.0.uf2","size":11,"sha256":"\#(digest)","update":"usb"},
             {"board":"heltec-t114","region":"US915","file":"tern-heltec-t114-us915-0.6.0.zip","size":12,"sha256":"\#(digest)","update":"bootloader"}
            ]}
            """#
        let m = try FirmwareManifest(json: Array(json.utf8))
        XCTAssertEqual(m.images.count, 2, "an image for a way this app does not know is left out")
        for (board, update) in [("heltec-v3", UInt8?.none), ("heltec-v3", 1), ("heltec-t114", 2), ("heltec-t114", 0)] {
            let how = UpdateMethod(board: board, update: update)
            let image = m.image(board: board, region: "us915", update: how)
            switch update {
            case nil, 1?: XCTAssertEqual(image?.size, 10)
            case 2?: XCTAssertEqual(image?.file, "tern-heltec-t114-us915-0.6.0.zip")
            default: XCTAssertNil(image)
            }
        }
        XCTAssertNil(m.image(board: "heltec-t114", region: "US915"), "an old app's choice: the link's, and there is none")
        XCTAssertNil(m.image(board: "heltec-v3", region: "US915", update: .bootloader))
        XCTAssertEqual(
            try? FirmwareManifest(json: Array(#"{"release":"1.0.0","images":[{"board":"b","region":"r","file":"f","size":1,"sha256":"\#(digest)","update":2}]}"#.utf8)),
            nil, "an update that is not a word")
    }

    // MARK: -

    /// Plays the node's half of `frames` to `connection`, checking the client sends its half.
    private func play(_ frames: [JSON], on connection: Connection, _ wire: Wire, line: UInt = #line) {
        for f in frames {
            XCTAssertLessThanOrEqual(wire.out.count, 1, "two requests at once", line: line)
            if f["from"]!.string == "client" {
                XCTAssertEqual(wire.out.first.map(Hex.encode), f["frame"]!.string, f["type"]!.string, line: line)
                if !wire.out.isEmpty { wire.out.removeFirst() }
            } else {
                connection.receive(f["frame"]!.bytes)
            }
        }
    }

    /// Answers the request `out` holds with `body`.
    private func answer(_ c: Connection, _ wire: Wire, _ body: Body) {
        let request = try! Frame.decode(wire.out.removeFirst())
        c.receive(try! Frame(seq: request.seq, body: body).encode())
    }
}

/// What a connection sends.
private final class Wire {
    var out: [[UInt8]] = []
}

/// A node played by hand, one request at a time, whose answers the test gives.
private final class UpdateNode: UpdateLink {
    var asked: [Body] = []
    var pending: ((Result<Body, RequestFailure>) -> Void)?
    /// Called once each request is out: a test that awaits answers here.
    var onSubmit: () -> Void = {}

    func submit(_ body: Body, then: @escaping (Result<Body, RequestFailure>) -> Void) {
        XCTAssertNil(pending, "two requests at once")
        asked.append(body)
        pending = then
        onSubmit()
    }

    /// A node that answers every request with `result`.
    static func answering(_ result: Result<Body, RequestFailure>) -> UpdateNode {
        let node = UpdateNode()
        node.onSubmit = { [unowned node] in node.answer(result) }
        return node
    }

    /// The request out.
    func take() -> Body? {
        asked.isEmpty ? nil : asked.removeFirst()
    }

    /// The offset of the `UPDATE_DATA` out.
    func takeOffset() -> Int? {
        if case let .updateData(offset, _)? = take() { Int(offset) } else { nil }
    }

    func answer(_ result: Result<Body, RequestFailure>) {
        let then = pending
        pending = nil
        then?(result)
    }
}

/// Finds a bootloader played by hand, made afresh each time it is looked for.
private final class FakeFinder: BootloaderFinder {
    var found = true
    var configure: (FakeBootloader) -> Void = { _ in }
    private(set) var looked: [Double] = []
    private(set) var bootloaders: [FakeBootloader] = []
    private(set) var released = 0

    func find(within seconds: Double) async -> DFUTransport? {
        looked.append(seconds)
        guard found else { return nil }
        let boot = FakeBootloader()
        configure(boot)
        bootloaders.append(boot)
        return boot
    }

    func disconnect() { released += 1 }
}
