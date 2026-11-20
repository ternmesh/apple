// Managing a node over the mesh: the frames against the specification's vectors
// (vectors/managing.json here, a copy of vectors/managing.json in ternmesh/spec), as a client, and
// `Remote`'s tries, greetings and trials against a manager played by hand.

import Foundation
import XCTest

@testable import TernKit

final class ManagingVectorTests: XCTestCase {
    static let vectors: [String: JSON] = {
        let url = Bundle.module.url(forResource: "managing", withExtension: "json", subdirectory: "vectors")!
        let data = try! Data(contentsOf: url)
        guard case let .object(o) = try! JSONDecoder().decode(JSON.self, from: data) else { fatalError() }
        return o
    }()

    var v: [String: JSON] { Self.vectors }

    func testParameters() {
        let p = v["parameters"]!
        XCTAssertEqual(Companion.owners, p["OWNERS"]!.int)
        XCTAssertEqual(Companion.requestMax, p["REQUEST_MAX"]!.int)
        XCTAssertEqual(Companion.answerMax, p["ANSWER_MAX"]!.int)
        XCTAssertEqual(Companion.meshAnswerWait, Double(p["MESH_ANSWER_WAIT"]!.int))
        XCTAssertEqual(Companion.trial, Double(p["TRIAL"]!.int))
    }

    /// A request is its kind and one companion request, which a `MANAGE` carries as it is.
    func testRequests() throws {
        for c in v["requests"]!.array {
            let why = c["why"]!.string
            let frame = c["frame"]!.bytes
            XCTAssertEqual(Hex.encode([Managing.requestKind] + frame), c["content"]!.string, why)
            let read = try Frame.decode(frame)
            XCTAssertTrue(read.body.type.isRequestType, why)
            XCTAssertTrue(Managing.allowed(read.body), why)
            XCTAssertNoThrow(try Frame(seq: 0, body: .manage(ref: 1, to: Address(Array(repeating: 1, count: 32))!, request: frame)).encode())
        }
    }

    /// An answer is its kind and companion frames, each after its length, packed into as few as
    /// fit; and they are read back from it.
    func testAnswers() throws {
        for c in v["answers"]!.array {
            let why = c["why"]!.string
            let frames = c["frames"]!.array.map(\.bytes)
            let contents = c["contents"]!.array.map(\.bytes)
            XCTAssertEqual(Managing.pack(frames).map { [Managing.answerKind] + $0 }, contents, why)
            XCTAssertEqual(contents.flatMap { Managing.unpack(Array($0.dropFirst()))! }, frames, why)
            for f in frames { XCTAssertNoThrow(try Frame.decode(f), why) }
        }
    }

    /// A request of no frame or too long is not one, nor an answer of no frame, of a frame of
    /// length 0, too long, or whose last length runs past its end.
    func testRejected() {
        for c in v["rejected"]!.array {
            let why = c["why"]!.string
            let content = c["content"]!.bytes
            switch content.first {
            case Managing.requestKind:
                let frame = Array(content.dropFirst())
                XCTAssertTrue(frame.isEmpty || frame.count > Companion.requestMax, why)
            case Managing.answerKind:
                XCTAssertNil(Managing.unpack(Array(content.dropFirst())), why)
            default:
                continue  // a notice, which the node reads and the client is told of as OWNER_CHANGED
            }
        }
    }

    /// What a client offers to ask over the mesh is what a managed node acts on there.
    func testAllowed() throws {
        let bob = Address(Array(repeating: 7, count: 32))!
        let hut = GroupID(Array(repeating: 0x48, count: 8))!
        let digest = Digest(Array(repeating: 0, count: 32))!
        func body(_ type: String, _ setting: JSON?) -> Body? {
            switch type {
            case "HELLO": .hello(version: 17)
            case "SYNC": .sync(after: 0)
            case "PING": .ping
            case "SET_TIME": .setTime(1)
            case "SET":
                switch setting!.int {
                case 1: .set(.region("EU868"))
                case 2: .set(.role(1))
                case 3: .set(.power(10))
                case 4: .set(.passkey(123_456))
                case 5: .set(.cards(1))
                case 6: .set(.cardName("Hut"))
                case 7: .set(.receiver(1))
                case 8: .set(.wake(600))
                case 9: .set(.listen(4))
                case 10: .set(.lock(1))
                default: nil
                }
            case "OFF": .off
            case "SEND": .send(ref: 1, to: bob, text: "x")
            case "READ": .read(through: 1)
            case "FORGET": .forget(contact: bob, through: 1)
            case "MANAGE": .manage(ref: 1, to: bob, request: [3, 1])
            case "OWNER": .owner(address: bob, owner: 1)
            case "SAVE_CONTACT": .saveContact(address: bob, name: "Bob")
            case "REMOVE_CONTACT": .removeContact(address: bob)
            case "END_SESSION": .endSession(address: bob)
            case "MAKE_GROUP": .makeGroup(name: "Hut")
            case "LEAVE_GROUP": .leaveGroup(group: hut)
            case "NAME_GROUP": .nameGroup(group: hut, name: "Hut")
            case "SEND_GROUP": .sendGroup(ref: 1, group: hut, text: "x")
            case "SEND_INVITE": .sendInvite(group: hut, to: bob)
            case "JOIN": .join(id: 1)
            case "GROUP_LINK": .groupLink(group: hut)
            case "JOIN_LINK": .joinLink(link: "x")
            case "FORGET_GROUP": .forgetGroup(group: hut, through: 1)
            case "UPDATE_BEGIN": .updateBegin(size: 1, digest: digest)
            case "UPDATE_DATA": .updateData(offset: 0, data: [1])
            case "UPDATE_END": .updateEnd
            case "SET_POSITION": .setPosition(lat: 0, lon: 0, altitude: 0, accuracy: 0, age: 0)
            case "SHARE": .share(contact: bob, PositionSharing.off)
            case "SHARE_GROUP": .shareGroup(group: hut, PositionSharing.off)
            case "UPDATE_BOOTLOADER": .updateBootloader
            case "WIPE": .wipe
            case "RESTART": .restart
            default: nil
            }
        }
        for c in v["allowed"]!.array {
            let type = c["type"]!.string
            let b = try XCTUnwrap(body(type, c["setting"]), type)
            XCTAssertEqual(b.name, type)
            XCTAssertEqual(Managing.allowed(b), c["allowed"]! == .bool(true), "\(type) \(String(describing: c["setting"]))")
        }
    }

    /// A sync over the mesh, read as a client reads it: the managed node itself, its owner, its
    /// neighbours, and then `SYNCED`.
    func testSyncs() throws {
        for c in v["syncs"]!.array {
            let frames = c["answers"]!.array.flatMap { Managing.unpack(Array($0.bytes.dropFirst()))! }
            var records = Records()
            var last: Body?
            for f in frames {
                let body = try Frame.decode(f).body
                if body.type.isNewsType { records.apply(body) } else { last = body }
            }
            guard case .synced = last else { return XCTFail("a sync ends with SYNCED") }
            XCTAssertEqual(records.me?.address, Address(c["self"]!["address"]!.bytes))
            XCTAssertEqual(records.me?.region, c["self"]!["region"]!.string)
            let owner = Address(c["owner"]!.bytes)!
            XCTAssertEqual(records.contacts.count, 1)
            XCTAssertEqual(records.contacts[owner]?.isOwner, true)
            XCTAssertEqual(records.neighbours.count, c["neighbours"]!.array.count)
            XCTAssertNotNil(records.airtime)
            XCTAssertNotNil(records.power)
            XCTAssertNotNil(records.fix)
            XCTAssertNotNil(records.sleep)
        }
    }
}

extension JSON: Equatable {
    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.int(x), .int(y)): x == y
        case let (.string(x), .string(y)): x == y
        default: false
        }
    }
}

/// `Remote` against a manager played by hand.
final class RemoteTests: XCTestCase {
    private let bob = Address([UInt8](repeating: 0xB0, count: 32))!
    private var time = 0.0
    /// Each `MANAGE` the remote asked the manager to send, and how to answer it.
    private var manages: [(request: [UInt8], then: (Result<Body, RequestFailure>) -> Void)] = []
    private var nextId: UInt32 = 100

    private func makeRemote() -> Remote {
        Remote(address: bob, now: { [unowned self] in time }, submit: { [unowned self] body, then in
            guard case let .manage(_, to, request) = body else { return XCTFail("\(body.name) is not a MANAGE") }
            XCTAssertEqual(to, bob)
            manages.append((request, then))
        })
    }

    /// The last `MANAGE`'s request, as the managed node reads it.
    private var asked: Frame { try! Frame.decode(manages.last!.request) }

    /// The manager queues the last `MANAGE`; returns its `id`.
    @discardableResult
    private func queue() -> UInt32 {
        nextId += 1
        manages.last!.then(.success(.queued(id: nextId)))
        return nextId
    }

    /// The managed node answers the last request with `bodies`, by way of the manager.
    private func answer(_ remote: Remote, from: Address? = nil, _ bodies: [Body]) {
        let seq = asked.seq
        let frames = bodies.map { try! Frame(seq: $0.type.isNewsType ? 0 : seq, body: $0).encode() }
        for a in Managing.pack(frames) { remote.take(.managed(from: from ?? bob, answer: a)) }
    }

    private func state(_ remote: Remote, _ id: UInt32, _ state: UInt8) {
        remote.take(.state(MessageState(id: id, state: state, reason: 0, wait: 0)))
    }

    private let info = Body.info(version: 17, firmware: "tern", board: "heltec-v3", release: "0.2.0", update: 1)

    /// `HELLO` first, then the request, each answered.
    private func greet(_ remote: Remote) {
        XCTAssertEqual(asked.body, .hello(version: Companion.version))
        queue()
        answer(remote, [info])
        XCTAssertEqual(remote.agreed, 17)
    }

    func testARequestNotDeliveredIsTriedAgainThreeTimesAsTheSameFrame() {
        let remote = makeRemote()
        var result: Result<Body, ManageFailure>?
        remote.request(.ping) { result = $0 }
        greet(remote)
        let frame = manages.last!.request
        XCTAssertEqual(asked.body, .ping)
        for tryNumber in 1...Remote.tries {
            XCTAssertEqual(remote.tries, tryNumber)
            XCTAssertEqual(manages.last!.request, frame, "the same frame, with the same seq")
            let id = queue()
            state(remote, id, MessageState.sent)
            XCTAssertEqual(remote.progress, MessageState.sent)
            state(remote, id, MessageState.notDelivered)
            time += Remote.lateAnswer - 1
            remote.tick()
            XCTAssertNil(result)
            time += 1
            remote.tick()
        }
        XCTAssertEqual(manages.count, 1 + Remote.tries)
        XCTAssertEqual(result, .failure(.notDelivered))
        XCTAssertFalse(remote.isBusy)
    }

    func testAnAnswerFromACopyThatArrivedIsTakenAfterNotDelivered() {
        let remote = makeRemote()
        var result: Result<Body, ManageFailure>?
        remote.request(.ping) { result = $0 }
        greet(remote)
        state(remote, queue(), MessageState.notDelivered)
        answer(remote, [.ok])
        XCTAssertEqual(result, .success(.ok))
    }

    func testDeliveredButUnansweredIsGivenUpAfterTheMeshAnswerWait() {
        let remote = makeRemote()
        var result: Result<Body, ManageFailure>?
        remote.request(.ping) { result = $0 }
        greet(remote)
        let id = queue()
        time += 500
        state(remote, id, MessageState.delivered)
        time += Companion.meshAnswerWait - 1
        remote.tick()
        XCTAssertNil(result)
        time += 1
        remote.tick()
        XCTAssertEqual(result, .failure(.noAnswer))
        XCTAssertEqual(manages.count, 2, "a request delivered is not sent again")
    }

    /// A node that has restarted answers `ERROR` 6: the remote says `HELLO` again, and asks once
    /// more.
    func testHelloAgainAfterTheNodeRestarted() {
        let remote = makeRemote()
        var result: Result<Body, ManageFailure>?
        remote.request(.set(.role(1))) { result = $0 }
        greet(remote)
        queue()
        answer(remote, [.error(code: ErrorCode.helloFirst)])
        XCTAssertNil(result)
        greet(remote)
        XCTAssertEqual(asked.body, .set(.role(1)))
        queue()
        answer(remote, [.ok])
        XCTAssertEqual(result, .success(.ok))
        XCTAssertNotNil(remote.trialEnds)
    }

    /// A `SET` that the node takes is on trial, and the remote confirms it with a `PING` at once;
    /// one that does not arrive leaves it on trial, to be confirmed by hand.
    func testASetIsOnTrialUntilConfirmed() {
        let remote = makeRemote()
        remote.request(.set(.cards(1)))
        greet(remote)
        queue()
        answer(remote, [.ok])
        XCTAssertEqual(remote.trialEnds, time + Companion.trial)
        XCTAssertNil(remote.settleEnds)
        XCTAssertEqual(asked.body, .ping, "confirmed at once")
        queue()
        answer(remote, [.ok])
        XCTAssertNil(remote.trialEnds)

        remote.request(.set(.receiver(0)))
        queue()
        answer(remote, [.ok])
        XCTAssertNotNil(remote.trialEnds)
        // The PING is not delivered, every time.
        for _ in 1...Remote.tries {
            state(remote, queue(), MessageState.notDelivered)
            time += Remote.lateAnswer
            remote.tick()
        }
        XCTAssertFalse(remote.isBusy)
        XCTAssertNotNil(remote.trialEnds, "still on trial")
        remote.confirm()
        XCTAssertEqual(asked.body, .ping)
        queue()
        answer(remote, [.ok])
        XCTAssertNil(remote.trialEnds)
    }

    /// A node restarts to apply a role or a power: the `PING` that confirms it, and anything else
    /// asked, waits until it can answer.
    func testARoleOrPowerWaitsForTheRestartBeforeItIsConfirmed() {
        let remote = makeRemote()
        remote.request(.set(.power(2)))
        greet(remote)
        queue()
        answer(remote, [.ok])
        var pinged: Result<Body, ManageFailure>?
        remote.request(.ping) { pinged = $0 }
        XCTAssertEqual(remote.settleEnds, time + Remote.restartSettle)
        XCTAssertEqual(remote.nextDeadline, remote.settleEnds)
        XCTAssertTrue(remote.isBusy)
        let count = manages.count
        time += Remote.restartSettle - 1
        remote.tick()
        XCTAssertEqual(manages.count, count, "nothing is sent while the node restarts")
        time += 1
        remote.tick()
        XCTAssertNil(remote.settleEnds)
        XCTAssertEqual(asked.body, .ping)
        queue()
        answer(remote, [.ok])
        XCTAssertNil(remote.trialEnds)
        XCTAssertNil(pinged, "the user's PING follows the one that confirms")
        queue()
        answer(remote, [.ok])
        XCTAssertEqual(pinged, .success(.ok))
        XCTAssertTrue(Remote.restarts(.role(1)))
        XCTAssertFalse(Remote.restarts(.lock(1)))
    }

    /// Answers from another node, or to a request given up on, are not taken; a sync holds only
    /// what it sent.
    func testOnlyItsOwnAnswersAndASyncIsWhole() {
        let remote = makeRemote()
        var result: Result<Body, ManageFailure>?
        remote.request(.sync(after: 0)) { result = $0 }
        greet(remote)
        XCTAssertEqual(asked.body, .sync(after: 0))
        queue()
        let carol = Address([UInt8](repeating: 0xCA, count: 32))!
        answer(remote, from: carol, [.synced(news: 1)])
        XCTAssertNil(result)
        let me = NodeSelf(address: bob, role: 1, region: "EU868", power: 14, time: 0, cards: 0, cardName: "", most: 0,
                          pairing: 1, locked: 1)
        answer(remote, [.nodeSelf(me), .contact(Contact(address: carol, session: 1, name: "Carol", wake: 0, owner: 1)),
                        .synced(news: 2)])
        XCTAssertEqual(result, .success(.synced(news: 2)))
        XCTAssertEqual(remote.records.me, me)
        XCTAssertEqual(remote.records.contacts[carol]?.isOwner, true)

        // A second sync that sends no contact leaves none.
        remote.refresh()
        queue()
        answer(remote, [.nodeSelf(me), .synced(news: 3)])
        XCTAssertTrue(remote.records.contacts.isEmpty)
    }

    /// What the node's version does not define is not asked, and a manager that refuses the
    /// `MANAGE` fails the request.
    func testUnsupportedAndRefusedByTheManager() {
        let remote = makeRemote()
        var results: [Result<Body, ManageFailure>] = []
        remote.request(.ping) { results.append($0) }
        XCTAssertEqual(asked.body, .hello(version: 17))
        queue()
        answer(remote, [.info(version: 16, firmware: "tern", board: "b", release: "r", update: 1)])
        queue()
        answer(remote, [.ok])
        remote.request(.set(.lock(1))) { results.append($0) }
        XCTAssertEqual(results, [.success(.ok), .failure(.unsupported)])
        remote.request(.ping) { results.append($0) }
        manages.last!.then(.failure(.refused(code: ErrorCode.notAContact)))
        XCTAssertEqual(results.last, .failure(.manager(.refused(code: ErrorCode.notAContact))))
        XCTAssertFalse(remote.isBusy)
    }

    /// `ERROR` 15: not an owner. Nothing else asked is sent, nothing is tried again, and the remote
    /// says so; an answer of any other kind says it is one.
    func testNotAnOwnerStopsAtOnce() {
        let remote = makeRemote()
        var owner: [Bool] = []
        remote.onOwner = { owner.append($0) }
        var results: [Result<Body, ManageFailure>] = []
        remote.request(.sync(after: 0)) { results.append($0) }
        remote.request(.ping) { results.append($0) }
        XCTAssertEqual(asked.body, .hello(version: 17))
        state(remote, queue(), MessageState.delivered)
        answer(remote, [.error(code: ErrorCode.notAnOwner)])
        XCTAssertEqual(results, [.failure(.notAnOwner), .failure(.notAnOwner)])
        XCTAssertEqual(owner, [false])
        XCTAssertFalse(remote.isBusy)
        time += 10_000
        remote.tick()
        XCTAssertEqual(manages.count, 1, "not tried again")
        XCTAssertEqual(Words.manage(.notAnOwner), Words.notAnOwner("that node"))

        // Asked again, and answered: an owner now.
        remote.request(.ping) { results.append($0) }
        greet(remote)
        queue()
        answer(remote, [.ok])
        XCTAssertEqual(results.last, .success(.ok))
        XCTAssertEqual(owner, [false, true, true])
    }

    /// A check is one `HELLO`: its `INFO` is the answer, and silence says nothing.
    func testACheckIsOneHello() {
        let remote = makeRemote()
        var owner: [Bool] = []
        remote.onOwner = { owner.append($0) }
        var result: Result<Body, ManageFailure>?
        remote.greet { result = $0 }
        XCTAssertEqual(asked.body, .hello(version: 17))
        queue()
        answer(remote, [info])
        XCTAssertEqual(result, .success(info))
        XCTAssertEqual(owner, [true])
        XCTAssertEqual(manages.count, 1)

        result = nil
        remote.greet { result = $0 }
        state(remote, queue(), MessageState.delivered)
        time += Companion.meshAnswerWait
        remote.tick()
        XCTAssertEqual(result, .failure(.noAnswer))
        XCTAssertEqual(owner, [true], "no answer says nothing")
    }

    /// The step a request is at: why it waits, as `STATE` says, until it is delivered.
    func testTheStepItIsAt() {
        let remote = makeRemote()
        remote.request(.ping)
        let id = queue()
        remote.take(.state(MessageState(id: id, state: MessageState.waiting, reason: 2, wait: 30)))
        XCTAssertEqual(remote.progress, MessageState.waiting)
        XCTAssertEqual(remote.reason, 2)
        XCTAssertEqual(remote.wait, 30)
        remote.take(.state(MessageState(id: id, state: MessageState.sent, reason: 0, wait: 0)))
        XCTAssertEqual(remote.reason, 0)
        XCTAssertEqual(remote.wait, 0)
    }

    /// A node known to sleep is waited for through its wake, its listen and `MESH_ANSWER_WAIT`.
    func testANodeThatSleepsIsWaitedForThroughItsWake() {
        let remote = makeRemote()
        remote.wakeHint = { 1800 }
        XCTAssertEqual(remote.wakes, Remote.Wakes(wake: 1800, listen: 255))
        let wait = 1800 + 255 + Companion.meshAnswerWait
        XCTAssertEqual(remote.sleepWait, wait)
        var result: Result<Body, ManageFailure>?
        remote.greet { result = $0 }
        let id = queue()
        // Delivered at once, as a keeper may say: its answer comes once the node wakes.
        state(remote, id, MessageState.delivered)
        time += wait - 1
        remote.tick()
        XCTAssertNil(result)
        time += 1
        remote.tick()
        XCTAssertEqual(result, .failure(.noAnswer))

        // Given up by the source before it woke: the keeper may still hold it.
        result = nil
        let start = time
        remote.greet { result = $0 }
        state(remote, queue(), MessageState.notDelivered)
        time = start + wait - 1
        remote.tick()
        XCTAssertNil(result)
        XCTAssertEqual(manages.count, 2)
        time += 1
        remote.tick()
        XCTAssertEqual(manages.count, 3, "then tried again")

        // Not delivered at all: waited for longer than `deliveryWait`.
        XCTAssertGreaterThan(wait, Remote.deliveryWait)
    }

    /// The node's own `SLEEP` comes before what is known from elsewhere: one that listens all the
    /// time is not waited for.
    func testItsOwnSleepComesFirst() {
        let remote = makeRemote()
        remote.wakeHint = { 1800 }
        remote.request(.sync(after: 0))
        greet(remote)
        queue()
        let me = NodeSelf(address: bob, role: 0, region: "EU868", power: 14, time: 7)
        answer(remote, [.nodeSelf(me), .sleep(Sleep(wake: 600, listen: 4, state: Sleep.asleep, keeper: 2, retry: 0)), .synced(news: 2)])
        XCTAssertEqual(remote.wakes, Remote.Wakes(wake: 600, listen: 4))
        remote.refresh()
        queue()
        answer(remote, [.nodeSelf(me), .sleep(Sleep(wake: 600, listen: 4, state: Sleep.awake, keeper: 0, retry: 0)), .synced(news: 2)])
        XCTAssertNil(remote.wakes)
        XCTAssertEqual(remote.sleepWait, 0)
    }
}

final class ManagingWordsTests: XCTestCase {
    func testOwnerChangedAndTheNewRefusalsInWords() {
        let hut = Address([UInt8](repeating: 0x48, count: 32))!
        let ada = Address([UInt8](repeating: 0xAD, count: 32))!
        XCTAssertEqual(
            Words.ownerChanged(OwnerChange(from: hut, contact: ada, owner: 1, by: OwnerChange.byLink), contact: "Ada", node: "Hut relay", you: false),
            "Ada was made an owner of Hut relay, at the node.")
        XCTAssertEqual(
            Words.ownerChanged(OwnerChange(from: hut, contact: ada, owner: 0, by: OwnerChange.byMesh), contact: "Ada", node: "Hut relay", you: true),
            "Your node is no longer an owner of Hut relay, over the mesh.")
        XCTAssertTrue(Words.error(ErrorCode.notOverMesh).contains("over the mesh"))
        XCTAssertTrue(Words.error(ErrorCode.locked).contains("locked"))
        XCTAssertEqual(Words.manage(.refused(code: ErrorCode.locked)), Words.error(ErrorCode.locked))
        XCTAssertTrue(
            Words.manageStep(MessageState.notDelivered, reason: 0, wait: 0, tries: 2, node: "Hut").contains("try 2 of 3"))
    }

    /// Each step a request to a managed node is at, as its `STATE` says.
    func testSteps() {
        func step(_ state: UInt8?, _ reason: UInt8 = 0, wait: UInt16 = 0, tries: Int = 1) -> String {
            Words.manageStep(state, reason: reason, wait: wait, tries: tries, node: "Hut relay")
        }
        XCTAssertEqual(step(nil), "Asking your node to send it…")
        XCTAssertEqual(step(MessageState.waiting, 2), "Making first contact with Hut relay…")
        XCTAssertEqual(step(MessageState.waiting, 1), "Finding a route…")
        XCTAssertEqual(step(MessageState.waiting, 4, wait: 180), "Waiting: the airtime budget, about 3 min")
        XCTAssertEqual(step(MessageState.waiting, 3), "Waiting: the region's transmit limit")
        XCTAssertEqual(step(MessageState.sent), "Sent over the mesh…")
        XCTAssertEqual(step(MessageState.delivered), "Delivered — waiting for Hut relay's answer")
        XCTAssertEqual(step(MessageState.sent, tries: 3), "Sent over the mesh… (try 3 of 3)")
        XCTAssertEqual(
            Words.asleep("Hut relay", wake: 900), "Hut relay is asleep: it wakes every 15 min, so this can take up to 15 min.")
        XCTAssertEqual(Words.manage(.noAnswer), "No answer. The node may be asleep or out of reach, or you're not an owner.")
        XCTAssertEqual(Words.notAnOwner("Hut relay"), "You're not an owner of Hut relay. Its owner can add you.")
        XCTAssertEqual(Words.notYours, "Not yours: its owner can add you.")
        XCTAssertNotEqual(Words.error(ErrorCode.notAnOwner), Words.error(200), "15 is named; an unknown code is not")
        XCTAssertEqual(Words.manage(.refused(code: 200)), "The node refused (200).")
    }
}

/// The nodes this client's node is an owner of.
final class OwnedTests: XCTestCase {
    private let me = Address([UInt8](repeating: 0xAA, count: 32))!
    private let hut = Address([UInt8](repeating: 0x48, count: 32))!
    private let ada = Address([UInt8](repeating: 0xAD, count: 32))!

    func testANoticeAboutThisNodeSaysWhetherItIsAnOwner() {
        var owned = Owned()
        XCTAssertNil(owned.isOwner(of: hut))
        XCTAssertTrue(owned.take(OwnerChange(from: hut, contact: me, owner: 1, by: OwnerChange.byMesh), me: me))
        XCTAssertEqual(owned.isOwner(of: hut), true)
        XCTAssertFalse(owned.take(OwnerChange(from: hut, contact: me, owner: 1, by: OwnerChange.byLink), me: me))
        XCTAssertTrue(owned.take(OwnerChange(from: hut, contact: me, owner: 0, by: OwnerChange.byLink), me: me))
        XCTAssertEqual(owned.isOwner(of: hut), false)
    }

    func testANoticeAboutAnotherAddressSaysNothingOfThisNode() {
        var owned = Owned()
        XCTAssertFalse(owned.take(OwnerChange(from: hut, contact: ada, owner: 1, by: OwnerChange.byMesh), me: me))
        XCTAssertFalse(owned.take(OwnerChange(from: hut, contact: me, owner: 1, by: OwnerChange.byMesh), me: nil))
        XCTAssertNil(owned.isOwner(of: hut))
    }

    func testKeptBetweenRuns() {
        var owned = Owned()
        owned.set(hut, owner: true)
        owned.set(ada, owner: false)
        var stored = owned.stored
        XCTAssertEqual(stored[hut.description], true)
        stored["not an address"] = true
        XCTAssertEqual(Owned(stored: stored), owned)
        XCTAssertEqual(Owned(stored: [:]), Owned())
    }
}
