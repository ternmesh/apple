// An image's signature, as companion.md's "Signed images" defines it: Ed25519 (RFC 8032, not
// prehashed) by a release key over the 48 bytes "TERN-FIRMWARE-V1" || SHA-256(image), the image
// exactly as published. The manifest carries each image's beside its SHA-256 (the site's
// `signature`, 128 hex digits), so the app checks it before downloading anything, and checks the
// downloaded bytes against that SHA-256 after.

public enum ImageSignature {
    public static let length = 64
    /// The 16 ASCII bytes that start what is signed.
    static let prefix = Array("TERN-FIRMWARE-V1".utf8)

    /// What a release key signs for an image whose SHA-256 is `digest`.
    public static func message(_ digest: Digest) -> [UInt8] { prefix + digest.bytes }

    /// Whether `signature` verifies over `digest` with one of `keys`: 64 bytes, an S below the
    /// group's order, made by one of them.
    public static func verifies(_ signature: [UInt8], digest: Digest, keys: [[UInt8]] = ReleaseKeys.all) -> Bool {
        let m = message(digest)
        return keys.contains { Ed25519.verify(signature: signature, message: m, key: $0) }
    }

    /// What the app knows of who made an image.
    public enum Check: Equatable, Sendable {
        /// Signed by a release key this app holds.
        case verified
        /// Signed, but not by a key this app holds, or not over this image: it may not be the
        /// release's.
        case notVerified
        /// No signature: a release from before releases were signed (0.6.0-alpha.1 and earlier).
        case unsigned
    }

    public static func check(_ signature: [UInt8]?, digest: Digest, keys: [[UInt8]] = ReleaseKeys.all) -> Check {
        guard let signature, !signature.isEmpty else { return .unsigned }
        return verifies(signature, digest: digest, keys: keys) ? .verified : .notVerified
    }
}
