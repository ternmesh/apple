// The battery and airtime the app keeps over time: what is kept, what goes, the file, and what a
// chart takes of them.

import XCTest

@testable import TernKit

final class ReadingsTests: XCTestCase {
    let t0: Int64 = 1_790_000_000_000

    private func power(_ mv: UInt16, _ pc: UInt8, _ fl: UInt8 = 0) -> Body { .power(Power(millivolts: mv, percent: pc, flags: fl)) }
    private func air(_ period: UInt32, _ allowed: UInt32, _ used: UInt32, _ wait: UInt32) -> Body {
        .airtime(Airtime(period: period, allowed: allowed, used: used, wait: wait))
    }

    func testAChangeIsKeptAtOnceAndTheSameValueOnlyAfterAWhile() {
        var r = Readings().with(power(4100, 90), at: t0)
        r = r.with(power(4100, 90), at: t0 + 10_000)
        XCTAssertEqual(r.power.count, 1, "the same, soon after, is not kept again")
        r = r.with(power(4080, 89), at: t0 + 20_000)
        XCTAssertEqual(r.power.count, 2)
        r = r.with(power(4080, 89), at: t0 + 20_000 + Readings.every)
        XCTAssertEqual(r.power.count, 3, "the same, a while after, is")
    }

    func testOtherNewsChangesNothing() {
        let r = Readings().with(power(4100, 90), at: t0)
        XCTAssertEqual(r.with(.neighbourGone(routingId: 1), at: t0 + 1), r)
    }

    func testAnEndKeepsTheLastAgainOnce() {
        var r = Readings().with(power(4100, 90), at: t0).with(air(3600, 36_000, 1_000, 0), at: t0)
        r = r.ended(at: t0 + 60_000)
        XCTAssertEqual(r.power.last, PowerReading(at: t0 + 60_000, millivolts: 4100, percent: 90, flags: 0, end: true))
        XCTAssertTrue(r.airtime.last!.end)
        XCTAssertEqual(r.ended(at: t0 + 70_000), r, "a second end adds nothing")
        r = r.with(power(4100, 90), at: t0 + 80_000)
        XCTAssertEqual(r.power.count, 3, "the same value after an end starts a new stretch")
    }

    func testAnEndAtNoTimeEndsWhereTheLastWasHeard() {
        let r = Readings().with(power(4100, 90), at: t0).ended(at: 0)
        XCTAssertEqual(r.power.last, PowerReading(at: t0, millivolts: 4100, percent: 90, flags: 0, end: true))
    }

    func testReadingsOlderThanAWeekGo() {
        var r = Readings().with(power(4100, 90), at: t0)
        r = r.with(power(4000, 80), at: t0 + Readings.kept + 1)
        XCTAssertEqual(r.power.map(\.percent), [80])
    }

    func testTheFileKeepsEverything() {
        let r = Readings()
            .with(power(4100, 255, 3), at: t0)
            .with(air(0, 0, 0, 0), at: t0 + 1)
            .with(air(3600, 36_000, 12_345, 2_000), at: t0 + 2)
            .ended(at: t0 + 3)
        XCTAssertEqual(Readings(decoding: r.encoded()), r)
        XCTAssertEqual(Readings(decoding: Data("something else".utf8)), Readings())
        let damaged = String(decoding: r.encoded(), as: UTF8.self) + "p x y z\na 1 2\np 1 99999 1 0\n"
        XCTAssertEqual(Readings(decoding: Data(damaged.utf8)), r)
    }

    func testTheAndroidAppsFileReads() {
        let android = "tern-readings 1\np 1790000000000 4100 255 3\na 1790000000001 3600 36000 12345 2000 e\n"
        let r = Readings(decoding: Data(android.utf8))
        XCTAssertEqual(r.power, [PowerReading(at: 1_790_000_000_000, millivolts: 4100, percent: 255, flags: 3)])
        XCTAssertEqual(r.airtime, [AirtimeReading(at: 1_790_000_000_001, period: 3600, allowed: 36000, used: 12345, wait: 2000, end: true)])
    }

    func testAChartTakesTheValueHeldAtItsStart() {
        let p = [ChartPoint(at: t0, value: 90, end: false), ChartPoint(at: t0 + 100, value: 80, end: false), ChartPoint(at: t0 + 200, value: 70, end: false)]
        XCTAssertEqual(ChartPoint.inSpan(p, from: t0 + 150), [ChartPoint(at: t0 + 150, value: 80, end: false), ChartPoint(at: t0 + 200, value: 70, end: false)])
        let ended = [ChartPoint(at: t0, value: 90, end: false), ChartPoint(at: t0 + 100, value: 90, end: true), ChartPoint(at: t0 + 300, value: 70, end: false)]
        XCTAssertEqual(ChartPoint.inSpan(ended, from: t0 + 150), [ChartPoint(at: t0 + 300, value: 70, end: false)])
        let runs = ChartPoint.runs(ended, to: t0 + 400)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1].last, ChartPoint(at: t0 + 400, value: 70, end: true), "the last run is held to now")
    }

    func testWaitsAreCountedOncePerRun() {
        let r = Readings(airtime: [
            AirtimeReading(at: t0, period: 3600, allowed: 36_000, used: 35_000, wait: 500),
            AirtimeReading(at: t0 + 1, period: 3600, allowed: 36_000, used: 35_500, wait: 300),
            AirtimeReading(at: t0 + 2, period: 3600, allowed: 36_000, used: 20_000, wait: 0),
            AirtimeReading(at: t0 + 3, period: 3600, allowed: 36_000, used: 36_000, wait: 900),
        ])
        XCTAssertEqual(r.waits(since: t0), 2)
        XCTAssertEqual(r.waits(since: t0 + 2), 1)
    }
}
