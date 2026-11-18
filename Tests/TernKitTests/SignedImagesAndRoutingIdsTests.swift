// Companion versions 13 and 14, as a client: routing ids made from the key blinded from an address
// against routing.md's vectors (vectors/routing.json here, a copy of the specification's), and
// release signatures against companion.md's (`signatures` in vectors/companion.json), with the test
// key those vectors publish. That key is given to the checks here, and is never one of the app's.

import Foundation
import XCTest

@testable import TernKit

final class SignedImagesAndRoutingIdsTests: XCTestCase {
    static let routing: [String: JSON] = {
        let url = Bundle.module.url(forResource: "routing", withExtension: "json", subdirectory: "vectors")!
        let data = try! Data(contentsOf: url)
        guard case let .object(o) = try! JSONDecoder().decode(JSON.self, from: data) else { fatalError() }
        return o
    }()

    var v: [String: JSON] { CompanionVectorTests.vectors }
    var testKey: [UInt8] { v["release_key"]!.bytes }

    // MARK: Routing ids (version 14)

    /// Every address in `ids`: its blinding scalar, its routing key and its routing id.
    func testRoutingIdsFromTheBlindedKey() throws {
        let ids = Self.routing["ids"]!.array
        XCTAssertGreaterThanOrEqual(ids.count, 7)
        for c in ids {
            let address = try XCTUnwrap(Address(c["address"]!.bytes))
            XCTAssertEqual(Hex.encode(RoutingIds.blind(address.bytes)), c["blind"]!.string, c["address"]!.string)
            XCTAssertEqual(address.routingKey.map(Hex.encode), c["key"]!.string, c["address"]!.string)
            XCTAssertEqual(address.routingId(version: 14), UInt32(c["id"]!.int), c["address"]!.string)
            // Asked again, from what was kept.
            XCTAssertEqual(address.routingId(version: 14), UInt32(c["id"]!.int))
            XCTAssertNotEqual(address.routingKey, address.bytes, "the key is not the address")
        }
    }

    /// No address in `no_ids` has a routing key, or an id: 0, which is no node's.
    func testAddressesWithNoRoutingId() throws {
        let none = Self.routing["no_ids"]!.array
        XCTAssertGreaterThanOrEqual(none.count, 4)
        for c in none {
            let address = try XCTUnwrap(Address(c["address"]!.bytes))
            XCTAssertNil(address.routingKey, c["why"]!.string)
            XCTAssertEqual(address.routingId(version: 14), 0, c["why"]!.string)
        }
    }

    /// The node's version says which: from the address itself up to 13, the blinded key from 14.
    func testTheDerivationFollowsTheNodesVersion() throws {
        let c = Self.routing["ids"]!.array[0]
        let address = try XCTUnwrap(Address(c["address"]!.bytes))
        let blinded = UInt32(c["id"]!.int)
        XCTAssertNotEqual(address.unblindedRoutingId, blinded)
        for version: UInt8? in [nil, 0, 12, 13] {
            XCTAssertEqual(address.routingId(version: version), address.unblindedRoutingId, "\(String(describing: version))")
        }
        for version: UInt8 in [14, 15] {
            XCTAssertEqual(address.routingId(version: version), blinded)
        }

        // The records' ids follow the version both ends spoke at their last sync.
        var r = Records()
        r.contacts[address] = Contact(address: address, session: 1, name: "Bob")
        r.syncedVersion = 13
        XCTAssertEqual(r.routingNames, [address.unblindedRoutingId: "Bob"])
        XCTAssertEqual(r.contact(routingId: address.unblindedRoutingId), address)
        XCTAssertNil(r.contact(routingId: blinded))
        r.syncedVersion = 14
        XCTAssertEqual(r.routingNames, [blinded: "Bob"])
        XCTAssertEqual(r.contact(routingId: blinded), address)
        XCTAssertNil(r.contact(routingId: address.unblindedRoutingId))
    }

    /// The exchange in vectors/companion.json is with a node of version 14: its group messages
    /// from the second address carry that address's blinded routing id.
    func testTheExchangesGroupMessagesCarryTheBlindedId() throws {
        let second = try XCTUnwrap(Address(hex: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"))
        var froms: Set<UInt32> = []
        for f in v["exchange"]!.array where f["type"]!.string == "GROUP_MESSAGE" {
            guard case let .groupMessage(m) = try Frame.decode(f["frame"]!.bytes).body else { return XCTFail() }
            if m.from != 0 { froms.insert(m.from) }
        }
        XCTAssertEqual(froms, [second.routingId(version: 14)])
        XCTAssertNotEqual(second.routingId(version: 14), second.unblindedRoutingId)
    }

    // MARK: Signed images (version 13)

    /// Every case in `signatures`: the message, and whether the signature verifies with the key.
    func testSignatures() throws {
        let cases = v["signatures"]!.array
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        for c in cases {
            let why = c["why"]!.string
            let digest = try XCTUnwrap(Digest(c["digest"]!.bytes))
            XCTAssertEqual(Hex.encode(ImageSignature.message(digest)), c["message"]!.string, why)
            let verifies: Bool = if case .bool(true) = c["verifies"]! { true } else { false }
            let key = c["release_key"]!.bytes
            XCTAssertEqual(ImageSignature.verifies(c["signature"]!.bytes, digest: digest, keys: [key]), verifies, why)
            // Among other keys, the same.
            XCTAssertEqual(ImageSignature.verifies(c["signature"]!.bytes, digest: digest, keys: [testKey.reversed(), key]), verifies, why)
            // And with no key, none verifies.
            XCTAssertFalse(ImageSignature.verifies(c["signature"]!.bytes, digest: digest, keys: []), why)
        }
    }

    /// The image of `update` is signed by the test key.
    func testTheImagesSignature() throws {
        let digest = try XCTUnwrap(Digest(v["image_digest"]!.bytes))
        XCTAssertEqual(SHA256.hash(v["image"]!.bytes), digest)
        let signature = v["image_signature"]!.bytes
        XCTAssertEqual(ImageSignature.check(signature, digest: digest, keys: [testKey]), .verified)
        XCTAssertEqual(ImageSignature.check(signature, digest: digest), .notVerified, "the app holds no test key")
        XCTAssertEqual(ImageSignature.check(nil, digest: digest), .unsigned)
        XCTAssertEqual(ImageSignature.check([], digest: digest), .unsigned)
    }

    /// The app holds release key 1 and nothing else: never the specification's test key, whose
    /// private half anyone has.
    func testTheReleaseKeys() {
        XCTAssertEqual(ReleaseKeys.all.map(Hex.encode), ["09800d79c2c3d0cab7f1710a18cd50d6f0e39c57d9cfe395b371195d4942f88d"])
        XCTAssertFalse(ReleaseKeys.all.contains(testKey))
        XCTAssertEqual(Hex.encode(testKey), "1a1d70f7c66db8fd2af5c179b7983c74b9bfb990b3d60d58d3fe06a63686b151")
        for key in ReleaseKeys.all { XCTAssertTrue(Ed25519.isValid(key)) }
    }

    // MARK: The manifest's signature, and what is offered

    func testTheManifestCarriesASignature() throws {
        let digest = v["image_digest"]!.string
        let signature = v["image_signature"]!.string
        let entry = #"{"board":"heltec-v3","region":"EU868","file":"f.bin","size":400,"sha256":"\#(digest)""#
        let signed = try FirmwareManifest(json: Array(#"{"release":"0.7.0","images":[\#(entry),"signature":"\#(signature)"}]}"#.utf8))
        XCTAssertEqual(signed.images[0].signature.map(Hex.encode), signature)
        XCTAssertEqual(signed.images[0].signatureCheck(keys: [testKey]), .verified)
        let unsigned = try FirmwareManifest(json: Array(#"{"release":"0.6.0-alpha.1","images":[\#(entry)}]}"#.utf8))
        XCTAssertNil(unsigned.images[0].signature)
        XCTAssertEqual(unsigned.images[0].signatureCheck(), .unsigned)
        for bad in ["\"\(signature.dropLast(2))\"", "\"\(signature.dropLast(2))zz\"", "64", "\"\""] {
            XCTAssertThrowsError(
                try FirmwareManifest(json: Array(#"{"release":"0.7.0","images":[\#(entry),"signature":\#(bad)}]}"#.utf8)), bad)
        }
    }

    /// A signed image is offered as it is; one not signed by a held key with a warning; and one
    /// with no signature, from before releases were signed, not at all to a node of version 13
    /// updated over the link, which would refuse it.
    func testWhatIsOffered() throws {
        let digest = try XCTUnwrap(Digest(v["image_digest"]!.bytes))
        let signature = v["image_signature"]!.bytes
        let image = { (signature: [UInt8]?, update: UpdateMethod) in
            FirmwareImage(board: "b", region: "r", file: "f", size: 400, sha256: digest, update: update, signature: signature)
        }
        for update in [UpdateMethod.link, .bootloader] {
            for version: UInt8 in [11, 12, 13, 14] {
                XCTAssertEqual(image(signature, update).offer(nodeVersion: version, keys: [testKey]), .signed)
                XCTAssertEqual(image(signature, update).offer(nodeVersion: version), .warn(.notVerified))
                let unsigned = image(nil, update).offer(nodeVersion: version)
                if update == .link, version >= 13 {
                    XCTAssertEqual(unsigned, .refusedByNode)
                } else {
                    XCTAssertEqual(unsigned, .warn(.unsigned), "\(update) \(version)")
                }
            }
        }
        XCTAssertNotNil(Words.signature(.unsigned))
        XCTAssertNotNil(Words.signature(.notVerified))
        XCTAssertNil(Words.signature(.verified))
    }

    /// `ERROR` 11 to `UPDATE_BEGIN` is the signature's: nothing was sent.
    func testErrorElevenAtTheBeginIsTheSignatures() throws {
        let refusals = v["refusals"]!.array
        let begin = try XCTUnwrap(refusals.first { $0["type"]!.string == "UPDATE_BEGIN" && $0["frame"]!.string.count == 2 * 39 })
        guard case let .updateBegin(_, digest, signature) = try Frame.decode(begin["frame"]!.bytes).body else { return XCTFail() }
        XCTAssertEqual(signature, [], "the one with no signature")
        let updater = Updater(image: v["image"]!.bytes, digest: digest)
        var asked: [Body] = []
        final class Refusing: UpdateLink {
            var asked: [Body] = []
            func submit(_ body: Body, then: @escaping (Result<Body, RequestFailure>) -> Void) {
                asked.append(body)
                then(.failure(.refused(code: ErrorCode.notAnImage)))
            }
        }
        let node = Refusing()
        updater.resume(on: node)
        asked = node.asked
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(updater.phase, .finished(.untrusted))
        XCTAssertTrue(Words.update(.untrusted).contains("not signed by a key this node trusts"))
    }
}
