// Frames on a byte stream (USB serial, TCP): a magic, a length, the frame and a CRC, with the
// node's console text between them. Bluetooth needs none of this: each write and notification is
// one frame already.

public enum ByteStream {
    public static let magic: [UInt8] = [0xF5, 0x54]

    /// CRC-16/IBM-3740: over "123456789" it is 0x29B1.
    public static func crc16<C: Sequence>(_ data: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// A frame as it goes on a byte stream: magic, length, the frame, and a CRC of the last two.
    public static func wrap(_ frame: [UInt8]) -> [UInt8] {
        var out = magic
        out += [UInt8(frame.count >> 8), UInt8(frame.count & 0xFF)]
        out += frame
        let crc = crc16(out[2...])
        out += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return out
    }
}

/// What a byte stream holds: a frame, or a run of bytes that is not one.
public enum StreamItem: Equatable, Sendable {
    case frame([UInt8])
    case text([UInt8])
}

/// Finds frames in a byte stream, and the text between them: a node's console shares the port.
/// `push` returns what the bytes so far complete, in order; what may yet be the start of a frame
/// is held (`pending`) until more arrives, or until `stale` says nothing more is coming.
public struct StreamReader: Sendable {
    public private(set) var pending: [UInt8] = []

    public init() {}

    public mutating func push<C: Sequence>(_ data: C) -> [StreamItem] where C.Element == UInt8 {
        pending += data
        return take()
    }

    /// After `Companion.gap` with nothing more: what is held is not the start of a frame after all.
    public mutating func stale() -> [StreamItem] {
        guard !pending.isEmpty else { return [] }
        let first = pending.removeFirst()
        var rest = take()
        if case let .text(text)? = rest.first {
            rest[0] = .text([first] + text)
            return rest
        }
        return [.text([first])] + rest
    }

    private mutating func take() -> [StreamItem] {
        var items: [StreamItem] = []
        var text: [UInt8] = []
        let b = pending
        var at = 0
        scan: while at < b.count {
            guard b[at] == 0xF5 else {
                text.append(b[at])
                at += 1
                continue
            }
            // What follows may be a frame: wait for as much as it takes to tell.
            guard at + 1 < b.count else { break scan }
            guard b[at + 1] == 0x54 else {
                text.append(b[at])
                at += 1
                continue
            }
            guard at + 4 <= b.count else { break scan }
            let length = Int(b[at + 2]) << 8 | Int(b[at + 3])
            guard (2...Companion.maxFrame).contains(length) else {
                text.append(b[at])
                at += 1
                continue
            }
            guard at + 6 + length <= b.count else { break scan }
            let crc = UInt16(b[at + 4 + length]) << 8 | UInt16(b[at + 5 + length])
            guard ByteStream.crc16(b[at + 2..<at + 4 + length]) == crc else {
                text.append(b[at])
                at += 1
                continue
            }
            if !text.isEmpty {
                items.append(.text(text))
                text = []
            }
            items.append(.frame(Array(b[at + 4..<at + 4 + length])))
            at += 6 + length
        }
        if !text.isEmpty {
            items.append(.text(text))
        }
        pending = Array(b[at...])
        return items
    }
}
