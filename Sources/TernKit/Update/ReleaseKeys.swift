// The release keys: the Ed25519 public keys of whoever publishes Tern's firmware, which a node
// takes an image over the companion link only if signed by (companion.md, "Signed images"). The
// same list as the firmware's ports/node/release_keys.h; the app checks an image against it before
// it sends one, either way, since a node's bootloader checks nothing.
//
// To add a key: one line, the key's 64 hex digits as `python3 tools/release_key.py public KEYFILE`
// (in ternmesh/firmware) prints them, under a comment saying when it was added, above the list's
// end. It must be one of ports/node/release_keys.h's. A key is changed by adding the new one beside the old, and dropping
// the old once releases signed with it are no longer offered (the firmware's docs/signing.md).
// The specification's published test key never goes here: its private half is in the vectors, for
// anyone to sign with. The tests give it to the checks themselves.

public enum ReleaseKeys {
    /// The keys this app takes an image's signature from.
    public static let all: [[UInt8]] = [
        // Release key 1, added 2026-11-18 (ternmesh/firmware#120).
        "09800d79c2c3d0cab7f1710a18cd50d6f0e39c57d9cfe395b371195d4942f88d",
    ].map { Hex.decode($0)! }
}
