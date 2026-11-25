// The node's battery and airtime over time, as this device heard them. The node keeps no history:
// it sends POWER and AIRTIME when they change, no more often than every QUIET seconds, and once in
// each sync, and the records hold only the last of each. So the app keeps what it hears, stamped
// with the device's clock, for the battery and airtime screens to draw.
//
// A reading the same as the one before is kept only once it is `every` after it, so that a value
// that holds still costs nothing; one that changes is kept at once. When the link ends, the last of
// each is kept again, marked as an end, so that a chart draws a value held up to then and no
// further: what the node did while the device was away is not known. Readings older than `kept` go.
//
// The file is the Android app's: a header line, then a line for each reading.

import Foundation

/// A `POWER`, at `at` on the device's clock (milliseconds since 1970); `end` if the link ended then.
public struct PowerReading: Equatable, Sendable {
    public var at: Int64
    public var millivolts: UInt16
    public var percent: UInt8
    public var flags: UInt8
    public var end: Bool

    public init(at: Int64, millivolts: UInt16, percent: UInt8, flags: UInt8, end: Bool = false) {
        self.at = at
        self.millivolts = millivolts
        self.percent = percent
        self.flags = flags
        self.end = end
    }

    /// The node's estimate of the charge left, nil when it has none.
    public var knownPercent: Int? { percent <= 100 ? Int(percent) : nil }
    public var charging: Bool { flags & 1 != 0 }
    public var external: Bool { flags & 2 != 0 }

    func sameAs(_ o: PowerReading) -> Bool { millivolts == o.millivolts && percent == o.percent && flags == o.flags }
}

/// An `AIRTIME`, at `at` on the device's clock; `end` if the link ended then.
public struct AirtimeReading: Equatable, Sendable {
    public var at: Int64
    public var period: UInt32
    public var allowed: UInt32
    public var used: UInt32
    public var wait: UInt32
    public var end: Bool

    public init(at: Int64, period: UInt32, allowed: UInt32, used: UInt32, wait: UInt32, end: Bool = false) {
        self.at = at
        self.period = period
        self.allowed = allowed
        self.used = used
        self.wait = wait
        self.end = end
    }

    /// How much of the period's allowance is used, 0 to 1; nil for a profile with no limit.
    public var fraction: Double? { period == 0 ? nil : min(1, Double(used) / Double(max(allowed, 1))) }

    func sameAs(_ o: AirtimeReading) -> Bool { period == o.period && allowed == o.allowed && used == o.used && wait == o.wait }
}

public struct Readings: Equatable, Sendable {
    public var power: [PowerReading]
    public var airtime: [AirtimeReading]

    /// How long a reading that holds still goes before it is kept again.
    public static let every: Int64 = 5 * 60_000
    /// How long a reading is kept.
    public static let kept: Int64 = 7 * 24 * 3_600_000
    /// The most of each kind kept, the newest.
    public static let most = 5000

    private static let header = "tern-readings 1"

    public init(power: [PowerReading] = [], airtime: [AirtimeReading] = []) {
        self.power = power
        self.airtime = airtime
    }

    /// These readings with `body`, a `POWER` or an `AIRTIME`, heard at `now`; any other body changes nothing.
    public func with(_ body: Body, at now: Int64) -> Readings {
        var r = self
        switch body {
        case let .power(p):
            let new = PowerReading(at: now, millivolts: p.millivolts, percent: p.percent, flags: p.flags)
            if let last = power.last, !last.end, last.sameAs(new), now - last.at < Self.every { return self }
            r.power = Self.trimmed(power + [new], now: now, at: \.at)
        case let .airtime(a):
            let new = AirtimeReading(at: now, period: a.period, allowed: a.allowed, used: a.used, wait: a.wait)
            if let last = airtime.last, !last.end, last.sameAs(new), now - last.at < Self.every { return self }
            r.airtime = Self.trimmed(airtime + [new], now: now, at: \.at)
        default:
            break
        }
        return r
    }

    /// The link ended at `now`: each last reading is kept again, as an end.
    public func ended(at now: Int64) -> Readings {
        var r = self
        if var p = power.last, !p.end {
            p.at = max(now, p.at)
            p.end = true
            r.power = Self.trimmed(power + [p], now: now, at: \.at)
        }
        if var a = airtime.last, !a.end {
            a.at = max(now, a.at)
            a.end = true
            r.airtime = Self.trimmed(airtime + [a], now: now, at: \.at)
        }
        return r
    }

    /// How many times since `from` the node said it had to wait to send: each run of readings with a wait, once.
    public func waits(since from: Int64) -> Int {
        var count = 0
        var waiting = false
        for r in airtime where r.at >= from {
            if r.end {
                waiting = false
                continue
            }
            if r.wait > 0 && !waiting { count += 1 }
            waiting = r.wait > 0
        }
        return count
    }

    private static func trimmed<T>(_ list: [T], now: Int64, at: KeyPath<T, Int64>) -> [T] {
        Array(list.drop { now - $0[keyPath: at] > kept }.suffix(most))
    }

    /// The readings as a file keeps them: a line for each, `p` or `a`, its time and its fields, and `e` for an end.
    public func encoded() -> Data {
        var s = Self.header + "\n"
        for p in power { s += "p \(p.at) \(p.millivolts) \(p.percent) \(p.flags)\(p.end ? " e" : "")\n" }
        for a in airtime { s += "a \(a.at) \(a.period) \(a.allowed) \(a.used) \(a.wait)\(a.end ? " e" : "")\n" }
        return Data(s.utf8)
    }

    /// Readings as `encoded` keeps them; a line that does not read is passed over, and a file that does not is none.
    public init(decoding data: Data) {
        self.init()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map(String.init) == Self.header else { return }
        for line in lines.dropFirst() {
            var f = line.split(separator: " ").map(String.init)
            guard let kind = f.first else { continue }
            let end = f.last == "e"
            if end { f.removeLast() }
            let n = f.dropFirst().compactMap { Int64($0) }
            guard n.count == f.count - 1 else { continue }
            if kind == "p", n.count == 4, let mv = UInt16(exactly: n[1]), let pc = UInt8(exactly: n[2]), let fl = UInt8(exactly: n[3]) {
                power.append(PowerReading(at: n[0], millivolts: mv, percent: pc, flags: fl, end: end))
            } else if kind == "a", n.count == 5, let pe = UInt32(exactly: n[1]), let al = UInt32(exactly: n[2]),
                      let us = UInt32(exactly: n[3]), let wa = UInt32(exactly: n[4]) {
                airtime.append(AirtimeReading(at: n[0], period: pe, allowed: al, used: us, wait: wa, end: end))
            }
        }
        power.sort { $0.at < $1.at }
        airtime.sort { $0.at < $1.at }
    }
}

/// One point of a chart: `value` from `at` until the next, or, if `end`, nothing after it.
public struct ChartPoint: Equatable, Sendable {
    public var at: Int64
    public var value: Double
    public var end: Bool

    public init(at: Int64, value: Double, end: Bool) {
        self.at = at
        self.value = value
        self.end = end
    }

    /// The points of `points` that a chart from `from` needs: those after it, and the one before it,
    /// which holds at its start. One that ended before `from` holds nothing.
    public static func inSpan(_ points: [ChartPoint], from: Int64) -> [ChartPoint] {
        let firstIn = points.firstIndex { $0.at >= from } ?? points.count
        var out: [ChartPoint] = []
        if firstIn > 0, !points[firstIn - 1].end {
            var before = points[firstIn - 1]
            before.at = from
            out.append(before)
        }
        return out + points[firstIn...]
    }

    /// `points` cut into runs, each ending at an end, the last held to `to` if it has none.
    public static func runs(_ points: [ChartPoint], to: Int64) -> [[ChartPoint]] {
        var runs: [[ChartPoint]] = []
        var run: [ChartPoint] = []
        for p in points {
            run.append(p)
            if p.end {
                runs.append(run)
                run = []
            }
        }
        if let last = run.last {
            var held = last
            held.at = max(to, last.at)
            held.end = true
            runs.append(run + [held])
        }
        return runs
    }
}
