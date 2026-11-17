// Just enough of a .zip file to read a DFU package: its central directory, and each entry's bytes,
// stored or deflated (RFC 1951), checked against the entry's CRC-32. `adafruit-nrfutil dfu genpkg`
// stores its entries; a package zipped again by hand may deflate them. Written here, as the
// manifest's JSON is, so that TernKit keeps to the standard library.
//
// No ZIP64, no encryption and no multi-disk archives: a DFU package is three small files.

/// A .zip file's entries, by name.
public struct ZipArchive {
    public enum ReadError: Error, Equatable {
        /// Not a .zip file, or one cut short.
        case notZip
        /// A kind of .zip this reader does not take: ZIP64, encrypted, or compressed other than
        /// stored or deflated.
        case unsupported(String)
        /// An entry whose bytes do not read, or whose CRC-32 is not theirs.
        case damaged(String)
    }

    struct Entry {
        var method: UInt16
        var flags: UInt16
        var crc: UInt32
        var compressed: Int
        var size: Int
        var offset: Int
    }

    private let bytes: [UInt8]
    private let entries: [String: Entry]

    /// The names of the entries.
    public var names: [String] { entries.keys.sorted() }

    public init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        // The end of central directory record: 22 bytes and a comment of up to 65535, at the end.
        let least = 22
        guard bytes.count >= least else { throw ReadError.notZip }
        var end: Int?
        var at = bytes.count - least
        let earliest = max(0, bytes.count - least - 0xFFFF)
        while at >= earliest {
            if Self.u32(bytes, at) == 0x0605_4B50 {
                end = at
                break
            }
            at -= 1
        }
        guard let end else { throw ReadError.notZip }
        let count = Int(Self.u16(bytes, end + 10))
        let directorySize = Int(Self.u32(bytes, end + 12))
        let directory = Int(Self.u32(bytes, end + 16))
        if count == 0xFFFF || directory == 0xFFFF_FFFF { throw ReadError.unsupported("ZIP64") }
        guard directory + directorySize <= end else { throw ReadError.notZip }

        var entries: [String: Entry] = [:]
        at = directory
        for _ in 0..<count {
            guard at + 46 <= end, Self.u32(bytes, at) == 0x0201_4B50 else { throw ReadError.notZip }
            let nameLength = Int(Self.u16(bytes, at + 28))
            let extraLength = Int(Self.u16(bytes, at + 30))
            let commentLength = Int(Self.u16(bytes, at + 32))
            guard at + 46 + nameLength <= end else { throw ReadError.notZip }
            let name = String(decoding: bytes[at + 46..<at + 46 + nameLength], as: UTF8.self)
            let entry = Entry(
                method: Self.u16(bytes, at + 10), flags: Self.u16(bytes, at + 8), crc: Self.u32(bytes, at + 16),
                compressed: Int(Self.u32(bytes, at + 20)), size: Int(Self.u32(bytes, at + 24)),
                offset: Int(Self.u32(bytes, at + 42)))
            if entry.compressed == 0xFFFF_FFFF || entry.size == 0xFFFF_FFFF || entry.offset == 0xFFFF_FFFF {
                throw ReadError.unsupported("ZIP64")
            }
            entries[name] = entry
            at += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The bytes of the entry `name`; nil if there is none.
    public func read(_ name: String) throws -> [UInt8]? {
        guard let e = entries[name] else { return nil }
        if e.flags & 1 != 0 { throw ReadError.unsupported("encrypted") }
        // The local header repeats the name and has its own extra field: the bytes follow those.
        guard e.offset + 30 <= bytes.count, Self.u32(bytes, e.offset) == 0x0403_4B50 else { throw ReadError.damaged(name) }
        let start = e.offset + 30 + Int(Self.u16(bytes, e.offset + 26)) + Int(Self.u16(bytes, e.offset + 28))
        guard start + e.compressed <= bytes.count else { throw ReadError.damaged(name) }
        let stored = bytes[start..<start + e.compressed]
        let out: [UInt8]
        switch e.method {
        case 0:
            out = Array(stored)
        case 8:
            guard let inflated = try? Inflate.run(stored, limit: e.size) else { throw ReadError.damaged(name) }
            out = inflated
        default:
            throw ReadError.unsupported("compression method \(e.method)")
        }
        guard out.count == e.size, CRC32.of(out) == e.crc else { throw ReadError.damaged(name) }
        return out
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= b.count else { return 0 }
        return UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= b.count else { return 0 }
        return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}

/// The CRC-32 a .zip file checks its entries with: ISO 3309's, reflected, as zlib computes it.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func of<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// Raw deflate, as RFC 1951 defines it: stored blocks, and blocks with the fixed or their own
/// Huffman codes.
enum Inflate {
    struct Invalid: Error {}

    /// The bytes `data` inflates to: no more than `limit`, so that a small entry cannot claim a
    /// huge one.
    static func run(_ data: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        var bits = Bits(data: Array(data))
        var out: [UInt8] = []
        out.reserveCapacity(limit)
        var last = false
        while !last {
            last = try bits.take(1) == 1
            switch try bits.take(2) {
            case 0:
                // Stored: from the next byte, a length, its complement, and that many bytes.
                bits.toByte()
                let length = try bits.take(16)
                guard try bits.take(16) == length ^ 0xFFFF else { throw Invalid() }
                guard out.count + length <= limit else { throw Invalid() }
                for _ in 0..<length { out.append(UInt8(try bits.take(8))) }
            case 1:
                try codes(&bits, &out, limit, Fixed.literals, Fixed.distances)
            case 2:
                let (literals, distances) = try dynamic(&bits)
                try codes(&bits, &out, limit, literals, distances)
            default:
                throw Invalid()
            }
        }
        return out
    }

    /// Lengths and distances: each length's base and extra bits (codes 257 to 285), and each
    /// distance's (codes 0 to 29), as section 3.2.5 lists them.
    static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
        6145, 8193, 12289, 16385, 24577,
    ]
    static let distanceExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    /// The order the code lengths' own code lengths come in (section 3.2.7).
    static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    enum Fixed {
        static let literals = Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })!
        static let distances = Huffman(lengths: [Int](repeating: 5, count: 30))!
    }

    /// A block's literal and length codes, then its distance codes, from the header that gives
    /// their lengths.
    static func dynamic(_ bits: inout Bits) throws -> (Huffman, Huffman) {
        let literalCount = try bits.take(5) + 257
        let distanceCount = try bits.take(5) + 1
        let lengthCount = try bits.take(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw Invalid() }
        var lengthLengths = [Int](repeating: 0, count: 19)
        for i in 0..<lengthCount { lengthLengths[order[i]] = try bits.take(3) }
        guard let lengthCode = Huffman(lengths: lengthLengths) else { throw Invalid() }

        var lengths: [Int] = []
        while lengths.count < literalCount + distanceCount {
            let symbol = try lengthCode.decode(&bits)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw Invalid() }
                lengths += [Int](repeating: previous, count: 3 + (try bits.take(2)))
            case 17:
                lengths += [Int](repeating: 0, count: 3 + (try bits.take(3)))
            default:
                lengths += [Int](repeating: 0, count: 11 + (try bits.take(7)))
            }
        }
        guard lengths.count == literalCount + distanceCount, lengths[256] > 0 else { throw Invalid() }
        guard let literals = Huffman(lengths: Array(lengths[0..<literalCount])),
              let distances = Huffman(lengths: Array(lengths[literalCount...]))
        else { throw Invalid() }
        return (literals, distances)
    }

    /// A block's literals and back references, up to its end code.
    static func codes(_ bits: inout Bits, _ out: inout [UInt8], _ limit: Int, _ literals: Huffman, _ distances: Huffman) throws {
        while true {
            let symbol = try literals.decode(&bits)
            if symbol < 256 {
                guard out.count < limit else { throw Invalid() }
                out.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let l = symbol - 257
                guard l < lengthBase.count else { throw Invalid() }
                let length = lengthBase[l] + (try bits.take(lengthExtra[l]))
                let d = try distances.decode(&bits)
                guard d < distanceBase.count else { throw Invalid() }
                let distance = distanceBase[d] + (try bits.take(distanceExtra[d]))
                guard distance <= out.count, out.count + length <= limit else { throw Invalid() }
                // A reference may overlap what it writes: byte by byte, it copies what it just wrote.
                let from = out.count - distance
                for i in 0..<length { out.append(out[from + i]) }
            }
        }
    }

    /// A canonical Huffman code, by how many codes there are of each length and the symbols in
    /// the order their codes count up (section 3.2.2).
    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        /// Nil if the lengths say more codes than there is room for. Fewer is allowed: a block
        /// with one distance code has a code of one bit with nothing for its other value.
        init?(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var room = 1
            for l in 1...15 {
                room = room * 2 - counts[l]
                if room < 0 { return nil }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<15 { offsets[l + 1] = offsets[l] + counts[l] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, l) in lengths.enumerated() where l > 0 {
                symbols[offsets[l]] = symbol
                offsets[l] += 1
            }
        }

        /// The next symbol: a bit at a time, the code so far against the first code of each length.
        func decode(_ bits: inout Bits) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for l in 1...15 {
                code |= try bits.take(1)
                let count = counts[l]
                if code - first < count { return symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw Invalid()
        }
    }

    /// The input, a bit at a time from each byte's least significant.
    struct Bits {
        let data: [UInt8]
        var at = 0
        var held = 0
        var count = 0

        mutating func take(_ n: Int) throws -> Int {
            while count < n {
                guard at < data.count else { throw Invalid() }
                held |= Int(data[at]) << count
                at += 1
                count += 8
            }
            let value = held & ((1 << n) - 1)
            held >>= n
            count -= n
            return value
        }

        /// Drops the bits left of the byte under way.
        mutating func toByte() {
            held = 0
            count = 0
        }
    }
}
