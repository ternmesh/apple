// Sharing an address off the air: draft/sharing.md in ternmesh/spec. The text form, the link a QR
// code holds, reading either back, and the short code two people compare. Nothing here touches the
// network: everything in an address is in its link.

public enum Sharing {
    /// The link's start: the address follows it in base32.
    public static let link = "HTTPS://TERNMESH.ORG/A/"

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8) // RFC 4648, section 6
    private static let base32Length = 52
    private static let shortCodeLabel = Array("tern short code".utf8)

    /// The address as a person reads it: 64 hex digits, upper-case.
    public static func text(_ address: Address) -> String { address.description.uppercased() }

    /// The text form in groups of eight, which is easier to read and still reads back.
    public static func grouped(_ address: Address) -> String {
        let t = Array(text(address))
        return stride(from: 0, to: t.count, by: 8).map { String(t[$0 ..< min($0 + 8, t.count)]) }.joined(separator: " ")
    }

    /// The link a QR code holds, all of it in the code's alphanumeric set.
    public static func link(_ address: Address) -> String { link + base32(address.bytes) }

    /// The address in a link or in the text form, or nil for anything else. Either case is ASCII's:
    /// a character outside ASCII is refused, even one a case mapping would turn into a letter, so
    /// that every address has exactly one link.
    public static func read(_ text: String) -> Address? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let bytes = Array(text.utf8)
        let start = Array(link.utf8)
        if bytes.count > start.count, bytes[..<start.count].map(upper) == start {
            return unbase32(Array(bytes[start.count...])).flatMap(Address.init)
        }
        let digits = bytes.filter { $0 != UInt8(ascii: " ") }
        guard digits.count == Address.length * 2 else { return nil }
        return Address(hex: String(decoding: digits, as: UTF8.self))
    }

    /// The twelve digits two people compare, as a number.
    public static func shortCodeValue(_ address: Address) -> UInt64 {
        let h = SHA256.hash(shortCodeLabel + address.bytes).bytes
        let n = h[0 ..< 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return n % 1_000_000_000_000
    }

    /// The short code as it is shown: twelve digits in three groups of four.
    public static func shortCode(_ address: Address) -> String { format(shortCodeValue(address)) }

    /// A code's value written as it is shown, leading zeros kept.
    public static func format(_ value: UInt64) -> String {
        let digits = String(value)
        let padded = Array(String(repeating: "0", count: max(0, 12 - digits.count)) + digits)
        return [0, 4, 8].map { String(padded[$0 ..< $0 + 4]) }.joined(separator: " ")
    }

    static func upper(_ c: UInt8) -> UInt8 {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(c) ? c - 32 : c
    }

    static func base32(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var n = 0
        var bits = 0
        for b in bytes {
            n = ((n << 8) | Int(b)) & 0xFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(n >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(n << (5 - bits)) & 31]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The 32 bytes of an address's canonical base32, either case, or nil.
    private static func unbase32(_ text: [UInt8]) -> [UInt8]? {
        text.count == base32Length ? unbase32Any(text) : nil
    }

    /// Canonical base32 of any length, either case, as bytes, or nil: a character outside the
    /// alphabet, a last character that carries no bit of any byte, or a spare bit set, which would
    /// give the same bytes two spellings.
    static func unbase32Any(_ text: [UInt8]) -> [UInt8]? {
        guard text.count * 5 % 8 < 5 else { return nil }
        var out: [UInt8] = []
        var n = 0
        var bits = 0
        for c in text {
            guard let v = alphabet.firstIndex(of: upper(c)) else { return nil }
            n = ((n << 5) | v) & 0xFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((n >> bits) & 0xFF))
            }
        }
        guard n & ((1 << bits) - 1) == 0 else { return nil }
        return out
    }
}
