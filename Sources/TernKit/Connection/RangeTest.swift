// A range test: numbered messages, "range #1", "range #2" and on, to one contact every so often,
// each logged with where the phone was when it went and, from the node's records, what became of
// it: delivered or not, and, from a node of version 18, how (ROUTE): the hops and signal of the
// acknowledgement's way back, its round trip, and the neighbour it first went to.
//
// What became of each ping is read from the records whenever it is asked for, not copied: a ROUTE
// or a STATE that comes later, even after the link dropped and came back, is in the next row.
// Nothing here has a clock or a radio of its own; the app runs the timer and sends what it says.

/// Where the phone was: degrees north and east, how exact in metres (nil for unknown), and how many
/// seconds old.
public struct PhoneFix: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var accuracy: Double?
    public var age: Int

    public init(lat: Double, lon: Double, accuracy: Double?, age: Int) {
        self.lat = lat
        self.lon = lon
        self.accuracy = accuracy
        self.age = age
    }
}

/// Why a ping did not reach the node as a message.
public enum Unsent: Equatable, Sendable {
    /// The node was not connected and synced when it was due.
    case notConnected
    /// The node refused it: no room, most often.
    case refused
    /// The node did not answer, or the link dropped first: it may have gone all the same, and is
    /// matched by its text once a sync shows it.
    case unanswered
}

/// One ping: its number `n`, when it was due (`at`, seconds since 1970), the `fix` the phone had
/// then, and the message it became, by `id`, once the node said or a sync showed it. `after` is the
/// greatest `id` the node held when it went, for that match.
public struct RangePing: Equatable, Sendable {
    public var n: Int
    public var at: Double
    public var text: String
    public var fix: PhoneFix?
    public var after: UInt32
    public var id: UInt32?
    public var unsent: Unsent?

    public init(n: Int, at: Double, text: String, fix: PhoneFix?, after: UInt32, id: UInt32? = nil, unsent: Unsent? = nil) {
        self.n = n
        self.at = at
        self.text = text
        self.fix = fix
        self.after = after
        self.id = id
        self.unsent = unsent
    }
}

/// A ping as the records leave it now: its message's state and route, nil for none yet.
public struct RangeRow: Equatable, Sendable, Identifiable {
    public var ping: RangePing
    public var state: UInt8?
    public var route: Route?

    public init(ping: RangePing, state: UInt8?, route: Route?) {
        self.ping = ping
        self.state = state
        self.route = route
    }

    public var id: Int { ping.n }
    public var isDelivered: Bool { state == MessageState.delivered }
}

/// The test itself: to the contact `to`, one ping each `interval` seconds, the first at once.
public struct RangeTest: Equatable, Sendable {
    public static let text = "range #"
    public static let intervals: ClosedRange<Double> = 30...60
    public static let defaultInterval = 30.0

    public let to: Address
    public let interval: Double
    public let startedAt: Double
    public private(set) var pings: [RangePing] = []

    public init(to: Address, interval: Double, startedAt: Double) {
        precondition(Self.intervals.contains(interval), "a ping every 30 to 60 s, not \(interval)")
        self.to = to
        self.interval = interval
        self.startedAt = startedAt
    }

    /// When the next ping is due.
    public var nextAt: Double { startedAt + Double(pings.count) * interval }

    /// The next ping, due now: logged at once, with `fix`, and `unsent` if it cannot go.
    public mutating func next(at: Double, fix: PhoneFix?, after: UInt32, unsent: Unsent? = nil) -> RangePing {
        let n = pings.count + 1
        let p = RangePing(n: n, at: at, text: "\(Self.text)\(n)", fix: fix, after: after, unsent: unsent)
        pings.append(p)
        return p
    }

    /// The node took ping `n` as the message `id`.
    public mutating func queued(_ n: Int, id: UInt32) {
        change(n) {
            $0.id = id
            $0.unsent = nil
        }
    }

    /// Ping `n` did not reach the node as a message, for `why`.
    public mutating func unsent(_ n: Int, _ why: Unsent) {
        change(n) { if $0.id == nil { $0.unsent = why } }
    }

    /// Pings the node did not answer for, matched against what it holds: a message to `to` with the
    /// ping's text, past what it held when the ping went, is the ping, and it went. Returns whether
    /// any was found.
    @discardableResult
    public mutating func resolve(_ records: Records) -> Bool {
        var changed = false
        for i in pings.indices where pings[i].id == nil && pings[i].unsent == .unanswered {
            let p = pings[i]
            let match = records.items.values.first { item in
                guard case let .message(m) = item else { return false }
                return m.id > p.after && m.contact == to && m.state != MessageState.received && m.text == p.text
            }
            guard let match else { continue }
            pings[i].id = match.id
            pings[i].unsent = nil
            changed = true
        }
        return changed
    }

    private mutating func change(_ n: Int, _ how: (inout RangePing) -> Void) {
        guard let i = pings.firstIndex(where: { $0.n == n }) else { return }
        how(&pings[i])
    }

    /// Each ping as `records` leave it now.
    public func rows(_ records: Records) -> [RangeRow] {
        pings.map { p in
            RangeRow(ping: p, state: p.id.flatMap { records.items[$0]?.state }, route: p.id.flatMap { records.routes[$0] })
        }
    }

    /// How many of `rows` were delivered, of those the node took.
    public static func tally(_ rows: [RangeRow]) -> (delivered: Int, sent: Int) {
        (rows.filter(\.isDelivered).count, rows.filter { $0.ping.id != nil }.count)
    }

    /// What became of a ping, in one word a spreadsheet can filter on.
    public static func result(_ r: RangeRow) -> String {
        switch r.ping.unsent {
        case .notConnected?: return "not_connected"
        case .refused?: return "refused"
        case .unanswered?: return "unanswered"
        case nil: break
        }
        guard r.ping.id != nil else { return "asking" }
        switch r.state {
        case MessageState.delivered?: return "delivered"
        case MessageState.notDelivered?: return "not_delivered"
        case MessageState.sent?: return "sent"
        case MessageState.waiting?: return "waiting"
        default: return "unknown"
        }
    }

    public static let csvHeader =
        "n,time,lat,lon,accuracy_m,fix_age_s,to,message_id,result,hops,snr_db,rssi_dbm,round_trip_s,tries,via_id,via"

    /// `rows` as CSV, one line each after a header, for a spreadsheet or a map: times as `time`
    /// writes them (ISO 8601), positions in degrees, SNR in dB, RSSI in dBm and the round trip in
    /// seconds; a field with nothing to say is empty. `name` names a routing id, or gives nil. The
    /// same columns as the Android app's.
    public func csv(_ rows: [RangeRow], time: (Double) -> String, name: (UInt32) -> String?) -> String {
        var out = Self.csvHeader + "\n"
        for r in rows {
            let p = r.ping
            let route = r.route
            // Hops, signal and round trip are the acknowledgement's: nothing until it is delivered.
            let back = route.flatMap { r.isDelivered && $0.hops > 0 ? $0 : nil }
            let via = route.flatMap { $0.via != 0 ? $0.via : nil }
            let fields: [String] = [
                "\(p.n)",
                time(p.at),
                p.fix.map { Self.fixed($0.lat, 7) } ?? "",
                p.fix.map { Self.fixed($0.lon, 7) } ?? "",
                p.fix?.accuracy.map { Self.fixed($0, 0) } ?? "",
                p.fix.map { "\($0.age)" } ?? "",
                String(to.description.prefix(8)),
                p.id.map { "\($0)" } ?? "",
                Self.result(r),
                back.map { "\($0.hops)" } ?? "",
                back.map { Self.fixed(Double($0.snr) / 4, 2) } ?? "",
                back.map { "\($0.rssi)" } ?? "",
                route.flatMap { $0.took > 0 ? Self.fixed(Double($0.took) / 1000, 3) : nil } ?? "",
                route.flatMap { $0.goes > 0 ? "\($0.goes)" : nil } ?? "",
                via.map(Words.routingId) ?? "",
                via.flatMap(name) ?? "",
            ]
            out += fields.map(Self.csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    /// `x` to `places` decimal places, rounded half away from zero, with a point whatever the locale.
    static func fixed(_ x: Double, _ places: Int) -> String {
        var scale = 1.0
        for _ in 0..<places { scale *= 10 }
        let n = Int64((abs(x) * scale).rounded())
        let sign = x < 0 && n != 0 ? "-" : ""
        guard places > 0 else { return sign + "\(n)" }
        let whole = n / Int64(scale)
        var frac = "\(n % Int64(scale))"
        while frac.count < places { frac = "0" + frac }
        return sign + "\(whole).\(frac)"
    }

    /// A field quoted only when it has to be: a comma, a quote or a line break in it.
    static func csvField(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        var quoted = "\""
        for c in s.unicodeScalars {
            if c == "\"" { quoted += "\"" }
            quoted.unicodeScalars.append(c)
        }
        return quoted + "\""
    }
}
