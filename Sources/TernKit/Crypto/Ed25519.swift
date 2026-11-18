// The Ed25519 a client needs, from libsodium: SHA-512, a scalar reduced mod L, whether 32 bytes
// are a valid address, a point multiplied by a scalar, and a signature checked. The standard
// library has no arithmetic for any of it, and none of it is written here: libsodium is the library
// the specification names (routing.md, companion.md's "Signed images"), and its tests hold it to
// RFC 8032. Everything passed through here is public (addresses, release keys, signatures), so
// nothing needs to be kept secret or run in constant time on this side.

import Clibsodium

enum Ed25519 {
    /// A scalar, reduced mod L, the order of the group, as 32 bytes little-endian.
    static let scalarLength = 32
    static let pointLength = 32
    static let signatureLength = 64

    /// libsodium picks its implementations once, before its first use. Safe to call from any
    /// thread, and any number of times.
    private static let ready: Bool = sodium_init() >= 0

    static func sha512(_ bytes: [UInt8]) -> [UInt8] {
        precondition(ready, "libsodium did not start")
        var out = [UInt8](repeating: 0, count: 64)
        _ = crypto_hash_sha512(&out, bytes, UInt64(bytes.count))
        return out
    }

    /// 64 bytes, read as a little-endian number, mod L: 32 bytes, little-endian.
    static func reduce(_ wide: [UInt8]) -> [UInt8] {
        precondition(ready && wide.count == 64)
        var out = [UInt8](repeating: 0, count: scalarLength)
        crypto_core_ed25519_scalar_reduce(&out, wide)
        return out
    }

    /// Whether `point` is the canonical encoding of a point of the prime-order subgroup other than
    /// the neutral element: a valid address, as first-contact.md has it. One of small order, with
    /// a part of small order, not canonical, or not on the curve, is not.
    static func isValid(_ point: [UInt8]) -> Bool {
        precondition(ready)
        return point.count == pointLength && crypto_core_ed25519_is_valid_point(point) == 1
    }

    /// `[scalar] point`, unclamped, or nil if the point is not valid or the product is the
    /// neutral element (as it is for a scalar of 0).
    static func multiply(_ scalar: [UInt8], _ point: [UInt8]) -> [UInt8]? {
        precondition(ready && scalar.count == scalarLength)
        guard isValid(point) else { return nil }
        var out = [UInt8](repeating: 0, count: pointLength)
        guard crypto_scalarmult_ed25519_noclamp(&out, scalar, point) == 0 else { return nil }
        return out
    }

    /// RFC 8032's verification (5.1.7), not prehashed: false for a signature that is not 64
    /// bytes, whose S is not below L, or that `key` did not make over `message`.
    static func verify(signature: [UInt8], message: [UInt8], key: [UInt8]) -> Bool {
        precondition(ready)
        guard signature.count == signatureLength, key.count == pointLength else { return false }
        return crypto_sign_ed25519_verify_detached(signature, message, UInt64(message.count), key) == 0
    }
}
