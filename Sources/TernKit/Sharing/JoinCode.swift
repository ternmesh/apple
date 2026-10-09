// A group's join code: draft/groups.md#join-codes in ternmesh/spec. The node writes the link and
// reads it; a client reads one only to say which group it is for before the user joins, and keeps
// neither the link nor the secret in it.

/// What a join code says, but for the secret: the group it is for, and what whoever made it calls
/// the group, a suggestion.
public struct JoinCode: Equatable, Sendable {
    public var group: GroupID
    public var name: String

    public init(group: GroupID, name: String) {
        self.group = group
        self.name = name
    }

    /// The link's start: the code follows it in base32.
    public static let link = "HTTPS://TERNMESH.ORG/G#"

    private static let secretLength = 16
    private static let codeMin = secretLength + 2
    private static let codeMax = codeMin + Companion.nameMax

    /// The group a join code is for, and its name, or nil: the scheme, host and `G` each in either
    /// case, and the base32 in either case, where either case is ASCII's, and nothing else, a check
    /// that fails or a name that is not UTF-8 included.
    public static func read(_ text: String) -> JoinCode? {
        guard text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let bytes = Array(text.utf8)
        let start = Array(link.utf8)
        guard bytes.count >= start.count, bytes[..<start.count].map(Sharing.upper) == start,
              var code = Sharing.unbase32Any(Array(bytes[start.count...]))
        else { return nil }
        defer { for i in code.indices { code[i] = 0 } }
        guard (codeMin ... codeMax).contains(code.count) else { return nil }
        var secret = Array(code[..<secretLength])
        defer { for i in secret.indices { secret[i] = 0 } }
        let raw = Array(code[codeMin...])
        let check = SHA256.hash(Array("tern group code".utf8) + secret + raw).bytes
        guard check[0] == code[secretLength], check[1] == code[secretLength + 1] else { return nil }
        // The standard library repairs bad UTF-8 when it makes a String; a join code is refused.
        let bad = transcode(raw.makeIterator(), from: UTF8.self, to: UTF32.self, stoppingOnError: true) { _ in }
        guard !bad else { return nil }
        return JoinCode(group: groupID(secret), name: String(decoding: raw, as: UTF8.self))
    }

    /// A group's id from its secret: Expand(G, "tern v0 group id", 8), HKDF-Expand with SHA-256.
    static func groupID(_ secret: [UInt8]) -> GroupID {
        GroupID(Array(hmac(key: secret, Array("tern v0 group id".utf8) + [1])[..<GroupID.length]))!
    }

    /// HMAC-SHA256 (RFC 2104), for a key no longer than a block.
    private static func hmac(key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        var block = key + [UInt8](repeating: 0, count: 64 - key.count)
        defer { for i in block.indices { block[i] = 0 } }
        let inner = SHA256.hash(block.map { $0 ^ 0x36 } + message).bytes
        return SHA256.hash(block.map { $0 ^ 0x5C } + inner).bytes
    }
}
