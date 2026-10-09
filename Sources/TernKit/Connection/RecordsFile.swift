// Records on disk, between runs of the app. The file holds the records as the frames that carried
// them, so it needs no format of its own past a short header: the codec that reads the node reads
// the file. The Android app writes the same bytes.
//
//   0–3   "TRNR"
//   4     the file's format, 1
//   5     syncedVersion, 0xFF for none
//   6     1 if missedSince is set, else 0
//   7–10  missedSince, big-endian, 0 when unset
//   then  entries to the end: a length byte n, then n bytes of a frame with seq 0, encoded at
//         Companion.version. SELF, every CONTACT, every GROUP, every MESSAGE, GROUP_MESSAGE and
//         INVITE in id order, every NEIGHBOUR, then AIRTIME and POWER, each only if held.
//
// A SELF from a node of version 5 or earlier, or one a client of version 5 wrote, ends before
// `cards` and `card_name`: it is read as version 5's, and says nothing of cards.
//
// Positions, sharing and cards are not kept. A position's age, sharing's minutes left and how long
// ago a card was heard are as of when the record was sent, so on disk they only grow wrong, and
// every sync sends each whole again. A file that holds them all the same is read, and they are
// passed over.

extension Records {
    static let fileMagic: [UInt8] = Array("TRNR".utf8)
    static let fileFormat: UInt8 = 1

    /// The records as the file holds them.
    public func encoded() -> [UInt8] {
        var out = Records.fileMagic
        out.append(Records.fileFormat)
        out.append(syncedVersion ?? 0xFF)
        out.append(missedSince == nil ? 0 : 1)
        let missed = missedSince ?? 0
        out += [UInt8(missed >> 24), UInt8(missed >> 16 & 0xFF), UInt8(missed >> 8 & 0xFF), UInt8(missed & 0xFF)]

        var bodies: [Body] = []
        if let me { bodies.append(.nodeSelf(me)) }
        bodies += contacts.values.sorted { $0.address.bytes.lexicographicallyPrecedes($1.address.bytes) }.map(Body.contact)
        bodies += groups.values.sorted { $0.group.bytes.lexicographicallyPrecedes($1.group.bytes) }.map(Body.group)
        for item in ordered {
            switch item {
            case let .message(m): bodies.append(.message(m))
            case let .groupMessage(m): bodies.append(.groupMessage(m))
            case let .invite(i): bodies.append(.invite(i))
            }
        }
        bodies += neighbours.values.sorted { $0.routingId < $1.routingId }.map(Body.neighbour)
        if let airtime { bodies.append(.airtime(airtime)) }
        if let power { bodies.append(.power(power)) }

        for body in bodies {
            // Every record here came from a frame that was read, so it builds again; one that did
            // not would be left out rather than spoil the rest.
            guard let frame = try? Frame(seq: 0, body: body).encode() else { continue }
            out.append(UInt8(frame.count))
            out += frame
        }
        return out
    }

    /// Records read back from `bytes`. A file that is not one, or is cut short or spoiled anywhere,
    /// gives empty records: the next sync, from 0, fetches everything again, which is better than
    /// holding half of it as if it were the whole.
    public init(decoding bytes: [UInt8]) {
        self.init()
        // A synced version this client does not speak, or a flag that is neither 0 nor 1, is a
        // spoiled file too: trusting it would sync from where it says, past what it lost.
        guard bytes.count >= 11, Array(bytes[0..<4]) == Records.fileMagic, bytes[4] == Records.fileFormat,
              bytes[5] == 0xFF || bytes[5] <= Companion.version, bytes[6] <= 1
        else {
            return
        }
        var r = Records()
        var at = 11
        while at < bytes.count {
            let n = Int(bytes[at])
            at += 1
            guard at + n <= bytes.count,
                  let frame = Records.kept(Array(bytes[at..<at + n])),
                  frame.body.isRecord || frame.body.isFleeting
            else { return }
            if frame.body.isRecord { r.apply(frame.body) }
            at += n
        }
        r.syncedVersion = bytes[5] == 0xFF ? nil : bytes[5]
        if bytes[6] == 1 {
            r.missedSince = UInt32(bytes[7]) << 24 | UInt32(bytes[8]) << 16 | UInt32(bytes[9]) << 8 | UInt32(bytes[10])
        }
        self = r
    }
}

extension Records {
    /// One of the file's frames. `SELF` is the one record a later version made longer, so one
    /// that does not read as this version's is read as the version before cards.
    static func kept(_ frame: [UInt8]) -> Frame? {
        if let read = try? Frame.decode(frame) { return read }
        guard frame.first == 0x80 else { return nil }
        return try? Frame.decode(frame, version: 5)
    }
}

extension Body {
    /// News that is the whole of one thing as the node holds it: what the file keeps.
    var isRecord: Bool {
        switch self {
        case .nodeSelf, .contact, .group, .message, .groupMessage, .invite, .neighbour, .airtime, .power: true
        default: false
        }
    }

    /// A record whose numbers count on from when it was sent: one the file does not keep.
    var isFleeting: Bool {
        switch self {
        case .position, .groupPosition, .sharing, .groupSharing, .card: true
        default: false
        }
    }
}
