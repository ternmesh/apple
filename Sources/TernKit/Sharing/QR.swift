// QR codes, written from ISO/IEC 18004, for the links the app shows: an address's
// (draft/sharing.md in ternmesh/spec) and a group's join code (draft/groups.md). Versions 1 to 5 at
// error correction level L, each one block of codewords, which is all those links need: an
// address's link fits version 3, and a join code version 4. A text is given as segments, each in
// the mode it is written in, so that a join code's link can be alphanumeric on either side of its
// `#`, which the alphanumeric set lacks: Core Image's generator writes it all as bytes.
//
// Nothing here draws: a code is its modules, true for dark, and the app draws them.

public enum QR {
    public enum Mode: String, Sendable { case alphanumeric, byte }

    public struct Segment: Equatable, Sendable {
        public var mode: Mode
        public var text: String

        public init(_ mode: Mode, _ text: String) {
            self.mode = mode
            self.text = text
        }
    }

    public enum Failure: Error { case notAlphanumeric, tooLong }

    private static let alphanumeric = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)

    /// Per version, from 1: data codewords and error correction codewords at level L, in one block.
    private static let blocks: [(data: Int, ec: Int)] = [(19, 7), (34, 10), (55, 15), (80, 20), (108, 26)]

    public static func isAlphanumeric(_ text: String) -> Bool {
        text.utf8.allSatisfy(alphanumeric.contains)
    }

    /// The segments a link is best written in: a join code's `#` alone in byte mode. A text with no
    /// `#` that is all alphanumeric is one segment; anything else is one byte segment.
    public static func segments(_ link: String) -> [Segment] {
        let parts = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy(isAlphanumeric) else { return [Segment(.byte, link)] }
        guard parts.count == 2 else { return [Segment(.alphanumeric, link)] }
        return [Segment(.alphanumeric, parts[0]), Segment(.byte, "#"), Segment(.alphanumeric, parts[1])]
            .filter { !$0.text.isEmpty }
    }

    /// A QR code of the segments: the smallest version from `least` that holds them, at level L,
    /// with `mask` or, if it is nil, the one the standard's penalty rules choose. Its modules, row
    /// by row, true for dark, with no quiet zone.
    public static func encode(_ segments: [Segment], least: Int = 1, mask: Int? = nil) throws -> [[Bool]] {
        var bits = Bits()
        for s in segments {
            switch s.mode {
            case .alphanumeric:
                let values = try s.text.utf8.map { c -> Int in
                    guard let v = alphanumeric.firstIndex(of: c) else { throw Failure.notAlphanumeric }
                    return v
                }
                bits.put(0b0010, 4)
                bits.put(values.count, 9) // versions 1 to 9
                var i = 0
                while i + 1 < values.count {
                    bits.put(values[i] * 45 + values[i + 1], 11)
                    i += 2
                }
                if values.count % 2 == 1 { bits.put(values[values.count - 1], 6) }
            case .byte:
                let bytes = Array(s.text.utf8)
                guard bytes.count < 256 else { throw Failure.tooLong }
                bits.put(0b0100, 4)
                bits.put(bytes.count, 8) // versions 1 to 9
                for b in bytes { bits.put(Int(b), 8) }
            }
        }
        var version = max(1, least)
        while version <= blocks.count, bits.count > blocks[version - 1].data * 8 { version += 1 }
        guard version <= blocks.count else { throw Failure.tooLong }
        let (dataWords, ecWords) = blocks[version - 1]
        let capacity = dataWords * 8
        // The terminator, up to four zeros; then to a whole byte; then the pad bytes in turn.
        bits.put(0, min(4, capacity - bits.count))
        bits.put(0, (8 - bits.count % 8) % 8)
        var pad = 0
        while bits.count < capacity {
            bits.put(pad == 0 ? 0xEC : 0x11, 8)
            pad ^= 1
        }
        var data: [UInt8] = []
        for i in stride(from: 0, to: capacity, by: 8) {
            data.append(bits.bits[i ..< i + 8].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) })
        }
        let words = data + correction(data, ecWords)
        let stream: [Bool] = words.flatMap { w -> [Bool] in (0 ..< 8).map { (w >> (7 - $0)) & 1 == 1 } }

        // The codewords up and down two columns at a time, from the right, around what is
        // reserved. The bits left over at the end, the remainder, are light.
        var (grid, reserved) = functionPatterns(version)
        let size = grid.count
        var k = 0
        var right = size - 1
        var up = true
        while right > 0 {
            if right == 6 { right = 5 } // the vertical timing pattern is never one of a pair
            for i in 0 ..< size {
                let y = up ? size - 1 - i : i
                for x in [right, right - 1] where !reserved[y][x] {
                    grid[y][x] = k < stream.count ? stream[k] : false
                    k += 1
                }
            }
            right -= 2
            up.toggle()
        }

        func masked(_ mask: Int) -> [[Bool]] {
            var m = grid
            for y in 0 ..< size {
                for x in 0 ..< size where !reserved[y][x] {
                    m[y][x] = grid[y][x] != apply(mask, x, y)
                }
            }
            writeFormat(&m, mask)
            return m
        }
        if let mask { return masked(mask) }
        return (0 ..< 8).map(masked).min { penalty($0) < penalty($1) }!
    }

    private struct Bits {
        var bits: [Bool] = []
        var count: Int { bits.count }
        mutating func put(_ value: Int, _ n: Int) {
            for i in stride(from: n - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
        }
    }

    // GF(256) with the polynomial x^8 + x^4 + x^3 + x^2 + 1.
    private static let (exp, log): ([UInt8], [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0 ..< 255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255 ..< 512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }

    /// The Reed-Solomon codewords for data: the remainder of data·x^n by the generator of degree n.
    private static func correction(_ data: [UInt8], _ n: Int) -> [UInt8] {
        var gen: [UInt8] = [1]
        for i in 0 ..< n {
            var next = [UInt8](repeating: 0, count: gen.count + 1)
            for j in 0 ..< gen.count {
                next[j] ^= gen[j]
                next[j + 1] ^= mul(gen[j], exp[i])
            }
            gen = next
        }
        var rem = [UInt8](repeating: 0, count: n)
        for d in data {
            let factor = d ^ rem.removeFirst()
            rem.append(0)
            for j in 0 ..< n { rem[j] ^= mul(gen[j + 1], factor) }
        }
        return rem
    }

    private static func functionPatterns(_ version: Int) -> (grid: [[Bool]], reserved: [[Bool]]) {
        let size = 17 + 4 * version
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
        var reserved = grid
        func set(_ x: Int, _ y: Int, _ dark: Bool) {
            guard x >= 0, y >= 0, x < size, y < size else { return }
            grid[y][x] = dark
            reserved[y][x] = true
        }
        // Finders, with their separators.
        for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4 ... 4 {
                for dx in -4 ... 4 {
                    let d = max(abs(dx), abs(dy))
                    set(cx + dx, cy + dy, d != 2 && d != 4)
                }
            }
        }
        // Timing.
        for i in 8 ..< size - 8 {
            set(i, 6, i % 2 == 0)
            set(6, i, i % 2 == 0)
        }
        // The one alignment pattern versions 2 to 6 have.
        if version >= 2 {
            let c = size - 7
            for dy in -2 ... 2 {
                for dx in -2 ... 2 { set(c + dx, c + dy, max(abs(dx), abs(dy)) != 1) }
            }
        }
        // The format information's places, written once the mask is chosen, and the dark module.
        for i in 0 ..< 9 {
            reserved[8][i] = true
            reserved[i][8] = true
        }
        for i in 0 ..< 8 {
            reserved[8][size - 1 - i] = true
            reserved[size - 1 - i][8] = true
        }
        set(8, size - 8, true)
        return (grid, reserved)
    }

    private static func apply(_ mask: Int, _ x: Int, _ y: Int) -> Bool {
        switch mask {
        case 0: (x + y) % 2 == 0
        case 1: y % 2 == 0
        case 2: x % 3 == 0
        case 3: (x + y) % 3 == 0
        case 4: (y / 2 + x / 3) % 2 == 0
        case 5: (x * y) % 2 + (x * y) % 3 == 0
        case 6: ((x * y) % 2 + (x * y) % 3) % 2 == 0
        default: ((x + y) % 2 + (x * y) % 3) % 2 == 0
        }
    }

    /// Level L's format information for a mask: five bits, BCH(15,5), XORed with 0x5412.
    private static func formatBits(_ mask: Int) -> Int {
        let data = 0b01 << 3 | mask
        var rem = data << 10
        for i in stride(from: 14, through: 10, by: -1) where (rem >> i) & 1 == 1 {
            rem ^= 0x537 << (i - 10)
        }
        return (data << 10 | rem) ^ 0x5412
    }

    private static func writeFormat(_ m: inout [[Bool]], _ mask: Int) {
        let size = m.count
        let f = formatBits(mask)
        func bit(_ i: Int) -> Bool { (f >> i) & 1 == 1 }
        // Around the top-left finder: bits 0 to 7 down column 8, 8 to 14 along row 8 leftwards.
        for i in 0 ... 5 { m[i][8] = bit(i) }
        m[7][8] = bit(6)
        m[8][8] = bit(7)
        m[8][7] = bit(8)
        for i in 9 ..< 15 { m[8][14 - i] = bit(i) }
        // And again beside the other two.
        for i in 0 ..< 8 { m[8][size - 1 - i] = bit(i) }
        for i in 8 ..< 15 { m[size - 15 + i][8] = bit(i) }
    }

    private static let finderLike: [[Bool]] = ["10111010000", "00001011101"].map { $0.map { $0 == "1" } }

    private static func penalty(_ m: [[Bool]]) -> Int {
        let size = m.count
        var score = 0
        var lines: [[Bool]] = []
        for i in 0 ..< size {
            lines.append(m[i])
            lines.append(m.map { $0[i] })
        }
        let light = [Bool](repeating: false, count: 4)
        for line in lines {
            // Runs of five or more of one colour.
            var run = 1
            for i in 1 ... size {
                if i < size, line[i] == line[i - 1] {
                    run += 1
                    continue
                }
                if run >= 5 { score += run - 2 }
                run = 1
            }
            // A finder's look: 1011101 with four light modules on either side, the quiet zone
            // around the code counted as light.
            let s = light + line + light
            for i in 0 ... s.count - 11 where finderLike.contains(where: { $0[...] == s[i ..< i + 11] }) {
                score += 40
            }
        }
        // Blocks of two by two of one colour.
        for y in 0 ..< size - 1 {
            for x in 0 ..< size - 1 {
                let c = m[y][x]
                if m[y][x + 1] == c, m[y + 1][x] == c, m[y + 1][x + 1] == c { score += 3 }
            }
        }
        // How far the dark modules are from half.
        let dark = m.reduce(0) { $0 + $1.filter { $0 }.count }
        score += abs(dark * 20 - size * size * 10) / (size * size) * 10
        return score
    }
}
