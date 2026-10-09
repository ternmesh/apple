// Where a node's firmware comes from: the release manifest at ternmesh.org, the image in it for a
// node's board and region, and whether that release is newer than the one the node runs.
//
//   https://ternmesh.org/firmware/latest.json
//   {"release":"0.2.0","images":[{"board":"heltec-v3","region":"EU868",
//     "file":"tern-heltec-v3-eu868-0.2.0-app.bin","size":1048576,"sha256":"<64 hex>"}]}
//
// `file` is relative to https://ternmesh.org/firmware/. The manifest is the site's contract, not
// the specification's: the companion protocol says only that a client finds an image by `INFO`'s
// `board` and `release`. Reading it needs a little JSON, written here so that TernKit keeps to
// the standard library.

/// One release of the firmware, as the site lists it.
public struct FirmwareManifest: Equatable, Sendable {
    /// Where the manifest is, and what each image's `file` is relative to.
    public static let latest = "https://ternmesh.org/firmware/latest.json"
    public static let base = "https://ternmesh.org/firmware/"

    /// The release's version, as Semantic Versioning writes one.
    public var release: String
    public var images: [FirmwareImage]

    public enum ReadError: Error, Equatable {
        /// Not JSON.
        case notJSON
        /// JSON, but not a manifest: `field` is missing or not what it should be.
        case bad(field: String)
    }

    public init(release: String, images: [FirmwareImage]) {
        self.release = release
        self.images = images
    }

    /// Reads the manifest's bytes. An image that is not one this client can use (a `file` that
    /// is not a plain name, a size of 0, a digest that is not 64 hex digits) is an error: the
    /// manifest is the site's, and a broken one is not to be guessed at.
    public init(json: [UInt8]) throws {
        guard let root = try? JSONValue.parse(json) else { throw ReadError.notJSON }
        guard case let .string(release)? = root["release"], SemanticVersion(release) != nil else {
            throw ReadError.bad(field: "release")
        }
        guard case let .array(list)? = root["images"] else { throw ReadError.bad(field: "images") }
        var images: [FirmwareImage] = []
        for entry in list {
            guard case let .string(board)? = entry["board"] else { throw ReadError.bad(field: "board") }
            guard case let .string(region)? = entry["region"] else { throw ReadError.bad(field: "region") }
            guard case let .string(file)? = entry["file"], FirmwareImage.isPlainName(file) else {
                throw ReadError.bad(field: "file")
            }
            guard case let .number(n)? = entry["size"], n >= 1, n <= Double(UInt32.max), n.rounded() == n else {
                throw ReadError.bad(field: "size")
            }
            guard case let .string(hex)? = entry["sha256"], hex.utf8.count == 64, let digest = Digest(hex: hex) else {
                throw ReadError.bad(field: "sha256")
            }
            images.append(FirmwareImage(board: board, region: region, file: file, size: Int(n), sha256: digest))
        }
        self.init(release: release, images: images)
    }

    /// The image for a node of `board` set to `region`, ignoring case; nil if there is none, or
    /// if either is empty: a node with no board cannot be updated over the companion protocol,
    /// and one with no region has no image to choose.
    public func image(board: String, region: String) -> FirmwareImage? {
        guard !board.isEmpty, !region.isEmpty else { return nil }
        return images.first { $0.board.lowercased() == board.lowercased() && $0.region.lowercased() == region.lowercased() }
    }

    /// This release against the one a node runs.
    public func compared(to running: String) -> ReleaseComparison {
        ReleaseComparison(offered: release, running: running)
    }
}

/// One image in a manifest.
public struct FirmwareImage: Equatable, Sendable {
    public var board: String
    public var region: String
    /// Its name, relative to `FirmwareManifest.base`.
    public var file: String
    public var size: Int
    public var sha256: Digest

    public init(board: String, region: String, file: String, size: Int, sha256: Digest) {
        self.board = board
        self.region = region
        self.file = file
        self.size = size
        self.sha256 = sha256
    }

    /// Where to download it.
    public var url: String { FirmwareManifest.base + file }

    /// Whether `bytes` are this image: its size, and its digest.
    public func matches(_ bytes: [UInt8]) -> Bool {
        bytes.count == size && SHA256.hash(bytes) == sha256
    }

    /// A name in the firmware directory, and nothing that would leave it.
    static func isPlainName(_ file: String) -> Bool {
        !file.isEmpty && !file.hasPrefix(".") && file.unicodeScalars.allSatisfy { c in
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "." || c == "-" || c == "_"
        }
    }
}

/// A release offered against the one a node runs.
public enum ReleaseComparison: Equatable, Sendable {
    /// The offered release is newer.
    case newer
    /// The node runs this release already.
    case same
    /// The node runs a newer one than is offered.
    case older
    /// The node's release is empty or not a version: a build made by hand, say. Whether the offer
    /// is newer is the user's call.
    case unknown

    public init(offered: String, running: String) {
        guard let o = SemanticVersion(offered), let r = SemanticVersion(running) else {
            self = .unknown
            return
        }
        self = o > r ? .newer : o == r ? .same : .older
    }
}

/// A version as Semantic Versioning 2.0.0 writes one, without a leading `v`, ordered by its
/// precedence: build metadata is kept but does not count, so two that differ only in it are equal.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: UInt64
    public var minor: UInt64
    public var patch: UInt64
    /// The pre-release's identifiers, empty for a release.
    public var prerelease: [String]
    public var build: [String]

    public init?(_ text: String) {
        var rest = Substring(text)
        var build: [String] = []
        if let plus = rest.firstIndex(of: "+") {
            build = rest[rest.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard build.allSatisfy({ !$0.isEmpty && Self.isIdentifier($0) }) else { return nil }
            rest = rest[..<plus]
        }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            prerelease = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard prerelease.allSatisfy({ !$0.isEmpty && Self.isIdentifier($0) && !Self.hasLeadingZero($0) }) else { return nil }
            rest = rest[..<dash]
        }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [UInt64] = []
        for part in core {
            guard !part.isEmpty, part.utf8.allSatisfy({ (0x30...0x39).contains($0) }), !Self.hasLeadingZero(String(part)),
                  let n = UInt64(part)
            else { return nil }
            numbers.append(n)
        }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
        self.prerelease = prerelease
        self.build = build
    }

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        if !build.isEmpty { s += "+" + build.joined(separator: ".") }
        return s
    }

    public static func == (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) == (b.major, b.minor, b.patch) && a.prerelease == b.prerelease
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A pre-release comes before its release.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            // Numbers have no leading zeros, so the shorter is the smaller, whatever their length.
            func numeric(_ s: String) -> Bool { s.utf8.allSatisfy { (0x30...0x39).contains($0) } }
            switch (numeric(x), numeric(y)) {
            case (true, true):
                return x.utf8.count != y.utf8.count
                    ? x.utf8.count < y.utf8.count
                    : Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8))
            // Numbers come before words; words go in ASCII order.
            case (true, false): return true
            case (false, true): return false
            case (false, false): return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8))
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    private static func isIdentifier(_ s: String) -> Bool {
        s.utf8.allSatisfy { c in
            (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x2D
        }
    }

    /// A number written with a leading zero, which Semantic Versioning does not allow.
    private static func hasLeadingZero(_ s: String) -> Bool {
        s.count > 1 && s.hasPrefix("0") && s.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}

/// Just enough JSON to read a manifest: RFC 8259, with numbers as `Double`.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    struct Invalid: Error {}

    subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { o[key] } else { nil }
    }

    static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var p = Parser(bytes: bytes)
        p.space()
        let value = try p.value(depth: 0)
        p.space()
        guard p.at == bytes.count else { throw Invalid() }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0

        var next: UInt8? { at < bytes.count ? bytes[at] : nil }

        mutating func space() {
            while let c = next, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { at += 1 }
        }

        mutating func expect(_ word: String) throws {
            for c in word.utf8 {
                guard next == c else { throw Invalid() }
                at += 1
            }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 64, let c = next else { throw Invalid() }
            switch c {
            case UInt8(ascii: "{"):
                at += 1
                var o: [String: JSONValue] = [:]
                space()
                if next == UInt8(ascii: "}") {
                    at += 1
                    return .object(o)
                }
                while true {
                    space()
                    let key = try string()
                    space()
                    try expect(":")
                    space()
                    o[key] = try value(depth: depth + 1)
                    space()
                    if next == UInt8(ascii: ",") { at += 1; continue }
                    try expect("}")
                    return .object(o)
                }
            case UInt8(ascii: "["):
                at += 1
                var a: [JSONValue] = []
                space()
                if next == UInt8(ascii: "]") {
                    at += 1
                    return .array(a)
                }
                while true {
                    space()
                    a.append(try value(depth: depth + 1))
                    space()
                    if next == UInt8(ascii: ",") { at += 1; continue }
                    try expect("]")
                    return .array(a)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func number() throws -> Double {
            let start = at
            if next == UInt8(ascii: "-") { at += 1 }
            guard let first = next, (0x30...0x39).contains(first) else { throw Invalid() }
            at += 1
            if first != 0x30 { digits() }
            if next == UInt8(ascii: ".") {
                at += 1
                guard digits() > 0 else { throw Invalid() }
            }
            if next == UInt8(ascii: "e") || next == UInt8(ascii: "E") {
                at += 1
                if next == UInt8(ascii: "+") || next == UInt8(ascii: "-") { at += 1 }
                guard digits() > 0 else { throw Invalid() }
            }
            guard let n = Double(String(decoding: bytes[start..<at], as: UTF8.self)) else { throw Invalid() }
            return n
        }

        @discardableResult
        mutating func digits() -> Int {
            let start = at
            while let c = next, (0x30...0x39).contains(c) { at += 1 }
            return at - start
        }

        mutating func string() throws -> String {
            try expect("\"")
            var out: [UInt8] = []
            while true {
                guard let c = next else { throw Invalid() }
                at += 1
                switch c {
                case UInt8(ascii: "\""):
                    // The standard library repairs bad UTF-8 when it makes a String; JSON rejects it.
                    let bad = transcode(out.makeIterator(), from: UTF8.self, to: UTF32.self, stoppingOnError: true) { _ in }
                    guard !bad else { throw Invalid() }
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard let e = next else { throw Invalid() }
                    at += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800...0xDBFF).contains(scalar) {
                            try expect("\\u")
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw Invalid() }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let u = Unicode.Scalar(scalar) else { throw Invalid() }
                        out += Array(String(Character(u)).utf8)
                    default: throw Invalid()
                    }
                default:
                    guard c >= 0x20 else { throw Invalid() }
                    out.append(c)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<4 {
                guard let c = next else { throw Invalid() }
                at += 1
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw Invalid()
                }
                v = v << 4 | d
            }
            return v
        }
    }
}
