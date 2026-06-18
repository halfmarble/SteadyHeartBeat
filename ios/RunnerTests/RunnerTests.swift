import XCTest
@testable import Runner

// Unit tests for the pure, HealthKit-/engine-free logic extracted from
// WorkoutManager (OvernightMath, AnnounceQueue). These run on the simulator — they
// touch no HealthKit, audio, or workout-session APIs. Run with:
//   xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
//     -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

final class OvernightMathTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
    private func seg(_ a: Double, _ b: Double, asleep: Bool) -> OvernightMath.Segment {
        OvernightMath.Segment(start: t(a), end: t(b), isAsleep: asleep)
    }
    // A scored night: bedEnd at `bedEndMin` (drives recency), `asleepH` hours of
    // sleep, sleep midpoint at `midTODh` o'clock (drives the normal-hours check).
    private func scored(bedEndMin: Double, asleepH: Double, midTODh: Double)
        -> OvernightMath.ScoredNight {
        OvernightMath.ScoredNight(
            night: OvernightMath.Night(
                sleepOnset: t(0), bedEnd: t(bedEndMin), asleepSeconds: asleepH * 3600,
                asleepIntervals: []),
            midpointTOD: midTODh * 3600)
    }

    // ── clusters ───────────────────────────────────────────────────────────────

    func testClustersSplitOnGapOverOneHour() {
        // 0–60 then a 4h gap to 300–360 → two nights.
        XCTAssertEqual(OvernightMath.clusters([seg(0, 60, asleep: true),
                                               seg(300, 360, asleep: true)]).count, 2)
    }

    func testClustersMergeAcrossSubHourGap() {
        // 40-minute gap → one night.
        XCTAssertEqual(OvernightMath.clusters([seg(0, 60, asleep: true),
                                               seg(100, 160, asleep: true)]).count, 1)
    }

    func testClustersEmpty() {
        XCTAssertTrue(OvernightMath.clusters([]).isEmpty)
    }

    // ── night(from:) ─────────────────────────────────────────────────────────────

    func testNightOnsetBedEndAndAsleepDuration() {
        // inBed 0–15 (awake), asleep 15–75, awake 75–80 → onset 15, bedEnd 75
        // (final wake — the trailing 75–80 in-bed-awake stretch is excluded),
        // 60m sleep.
        let n = OvernightMath.night(from: [
            seg(0, 15, asleep: false),
            seg(15, 75, asleep: true),
            seg(75, 80, asleep: false),
        ])
        XCTAssertEqual(n?.sleepOnset, t(15))
        XCTAssertEqual(n?.bedEnd, t(75))
        XCTAssertEqual(n?.asleepSeconds, 60 * 60)
    }

    func testNightNilWhenNoAsleepSegment() {
        // Only inBed recorded (iPhone-only, no stage classification).
        XCTAssertNil(OvernightMath.night(from: [seg(0, 100, asleep: false)]))
    }

    func testNightIsAsleepMarksOnlyAsleepSpans() {
        // asleep 15–75 inside an in-bed 0–80 window: a sample at 40 is asleep,
        // one at 5 (awake-in-bed) and one at 78 (awake-in-bed) are not. This is
        // exactly the sleep-HRV bucketing.
        let n = OvernightMath.night(from: [
            seg(0, 15, asleep: false),
            seg(15, 75, asleep: true),
            seg(75, 80, asleep: false),
        ])!
        XCTAssertTrue(n.isAsleep(at: t(40)))
        XCTAssertFalse(n.isAsleep(at: t(5)))
        XCTAssertFalse(n.isAsleep(at: t(78)))
        // Boundary is half-open: exactly at the segment end is not asleep.
        XCTAssertFalse(n.isAsleep(at: t(75)))
    }

    // ── unionDuration (no double-counting across overlapping sources) ────────────

    func testUnionDurationMergesOverlap() {
        // [0,60] ∪ [30,90] = 90 minutes, not 120.
        XCTAssertEqual(OvernightMath.unionDuration([(t(0), t(60)), (t(30), t(90))]), 90 * 60)
    }

    func testUnionDurationDisjoint() {
        XCTAssertEqual(OvernightMath.unionDuration([(t(0), t(60)), (t(120), t(150))]), 90 * 60)
    }

    // ── circular time-of-day ────────────────────────────────────────────────────

    func testCircularMeanWrapsMidnight() {
        // 23:00 and 01:00 average to 00:00, not noon.
        XCTAssertEqual(OvernightMath.circularMeanTOD([23 * 3600, 1 * 3600]) ?? -1, 0, accuracy: 1)
    }

    func testCircularMeanSimple() {
        XCTAssertEqual(OvernightMath.circularMeanTOD([2 * 3600, 4 * 3600]) ?? -1, 3 * 3600, accuracy: 1)
    }

    func testCircularMeanEmptyNil() {
        XCTAssertNil(OvernightMath.circularMeanTOD([]))
    }

    func testCircularDistanceWraps() {
        XCTAssertEqual(OvernightMath.circularDistanceTOD(23.5 * 3600, 0.5 * 3600), 3600, accuracy: 0.001)
    }

    func testCircularDistanceDirect() {
        XCTAssertEqual(OvernightMath.circularDistanceTOD(1 * 3600, 4 * 3600), 3 * 3600, accuracy: 0.001)
    }

    // ── selectNight (≥3h asleep, within normal hours, most recent) ───────────────

    func testSelectsMostRecentQualifyingNight() {
        let older = scored(bedEndMin: 60, asleepH: 7, midTODh: 3)
        let newer = scored(bedEndMin: 200, asleepH: 7, midTODh: 3)
        XCTAssertEqual(OvernightMath.selectNight([older, newer])?.bedEnd, t(200))
    }

    func testRejectsShortNapInFavorOfRealNight() {
        // A recent 1-hour nap is below the 3h floor → the older 7h night wins.
        let realNight = scored(bedEndMin: 60, asleepH: 7, midTODh: 3)
        let nap = scored(bedEndMin: 500, asleepH: 1, midTODh: 14)
        XCTAssertEqual(OvernightMath.selectNight([realNight, nap])?.bedEnd, t(60))
    }

    func testRejectsLongDaytimeNapOutsideNormalHours() {
        // Three night-time nights set "normal" ≈ 3 AM; a recent 3.5h afternoon
        // nap is >3h but outside normal hours → most recent night-time night wins.
        let n1 = scored(bedEndMin: 10, asleepH: 7, midTODh: 3)
        let n2 = scored(bedEndMin: 20, asleepH: 7, midTODh: 3)
        let n3 = scored(bedEndMin: 30, asleepH: 7, midTODh: 3)
        let nap = scored(bedEndMin: 500, asleepH: 3.5, midTODh: 15)
        XCTAssertEqual(OvernightMath.selectNight([n1, n2, n3, nap])?.bedEnd, t(30))
    }

    func testColdStartRejectsLoneDaytimeNap() {
        // No history → default overnight band (~3 AM). A lone 4h 2 PM nap is out.
        XCTAssertNil(OvernightMath.selectNight([scored(bedEndMin: 60, asleepH: 4, midTODh: 14)]))
    }

    func testColdStartAcceptsLoneNightSleep() {
        XCTAssertEqual(
            OvernightMath.selectNight([scored(bedEndMin: 60, asleepH: 7, midTODh: 3)])?.bedEnd, t(60))
    }

    func testSelectNightNilWhenNothingQualifies() {
        XCTAssertNil(OvernightMath.selectNight([]))
        // All naps below the floor → nil.
        XCTAssertNil(OvernightMath.selectNight([scored(bedEndMin: 60, asleepH: 2, midTODh: 3)]))
    }

    // ── qualifyingNights (daily-trends series) ───────────────────────────────────

    func testQualifyingNightsReturnsAllOldestFirst() {
        let nights = OvernightMath.qualifyingNights([
            scored(bedEndMin: 200, asleepH: 7, midTODh: 3),
            scored(bedEndMin: 10, asleepH: 7, midTODh: 3),
            scored(bedEndMin: 100, asleepH: 7, midTODh: 3),
        ])
        XCTAssertEqual(nights.map { $0.bedEnd }, [t(10), t(100), t(200)])
    }

    func testQualifyingNightsExcludesNapsAndOddHours() {
        // Three night-time nights set normal ~3 AM; a long afternoon nap and a
        // short night are both dropped.
        let kept = OvernightMath.qualifyingNights([
            scored(bedEndMin: 10, asleepH: 7, midTODh: 3),
            scored(bedEndMin: 20, asleepH: 7, midTODh: 3),
            scored(bedEndMin: 30, asleepH: 7, midTODh: 3),
            scored(bedEndMin: 40, asleepH: 2, midTODh: 3),   // too short
            scored(bedEndMin: 50, asleepH: 3.5, midTODh: 15), // daytime
        ])
        XCTAssertEqual(kept.map { $0.bedEnd }, [t(10), t(20), t(30)])
    }

    func testQualifyingNightsEmpty() {
        XCTAssertTrue(OvernightMath.qualifyingNights([]).isEmpty)
    }

    // ── mean ─────────────────────────────────────────────────────────────────

    func testMeanAverages() {
        XCTAssertEqual(OvernightMath.mean([40, 50, 60]), 50)
    }

    func testMeanOfEmptyIsNil() {
        XCTAssertNil(OvernightMath.mean([]))
    }

    // ── median (bed HRV) ───────────────────────────────────────────────────────

    func testMedianOddCountIsMiddle() {
        XCTAssertEqual(OvernightMath.median([50, 10, 30]), 30) // sorted: 10,30,50
    }

    func testMedianEvenCountAveragesMiddleTwo() {
        XCTAssertEqual(OvernightMath.median([10, 20, 30, 40]), 25)
    }

    func testMedianRejectsOutlier() {
        // A single movement-artifact spike must not drag the result the way a
        // mean would: mean([45,48,52,300]) = 111.25, but median = 50.
        XCTAssertEqual(OvernightMath.median([45, 48, 52, 300]), 50)
    }

    func testMedianOfEmptyIsNil() {
        XCTAssertNil(OvernightMath.median([]))
    }
}

final class AnnounceQueueTests: XCTestCase {
    private struct Item: Equatable { let id: Int; let isBpm: Bool }
    private func enqueue(_ q: [Item], _ x: Item) -> [Item] {
        AnnounceQueue.enqueue(q, x) { $0.isBpm }
    }

    func testAppendsOntoEmpty() {
        XCTAssertEqual(enqueue([], Item(id: 1, isBpm: true)), [Item(id: 1, isBpm: true)])
    }

    func testNonBpmAlwaysAppends() {
        // A non-BPM cue appends even when a BPM is already waiting.
        let q = [Item(id: 1, isBpm: true)]
        XCTAssertEqual(enqueue(q, Item(id: 2, isBpm: false)),
                       [Item(id: 1, isBpm: true), Item(id: 2, isBpm: false)])
    }

    func testBpmReplacesWaitingBpmInPlace() {
        // [A(non), B(bpm), C(non)] + D(bpm) → B replaced by D, order preserved.
        let q = [Item(id: 1, isBpm: false), Item(id: 2, isBpm: true), Item(id: 3, isBpm: false)]
        XCTAssertEqual(enqueue(q, Item(id: 4, isBpm: true)),
                       [Item(id: 1, isBpm: false), Item(id: 4, isBpm: true), Item(id: 3, isBpm: false)])
    }

    func testBpmAppendsWhenNoBpmWaiting() {
        let q = [Item(id: 1, isBpm: false)]
        XCTAssertEqual(enqueue(q, Item(id: 2, isBpm: true)),
                       [Item(id: 1, isBpm: false), Item(id: 2, isBpm: true)])
    }

    func testBpmReplacesOnlyTheFirstWaitingBpm() {
        // Invariant: at most one BPM is ever waiting, but guard the rule anyway —
        // only the first match is replaced.
        let q = [Item(id: 1, isBpm: true), Item(id: 2, isBpm: true)]
        XCTAssertEqual(enqueue(q, Item(id: 3, isBpm: true)),
                       [Item(id: 3, isBpm: true), Item(id: 2, isBpm: true)])
    }
}

// WorkoutManager.droppingCurrentDay — the pure rule that keeps a partial current
// day out of the daily-history trends (resting/walking HR, steps, HR min/max).
final class DailyHistoryTests: XCTestCase {
    private let day: TimeInterval = 86400

    private func dates(_ pts: [[String: Any]]) -> [TimeInterval] {
        pts.map { $0["date"] as! Double }
    }

    func testDropsTodayKeepsEarlierDays() {
        let todayStart = 10 * day
        let pts: [[String: Any]] = [
            ["date": 8 * day, "value": 1.0],
            ["date": 9 * day, "value": 2.0],
            ["date": 10 * day, "value": 3.0],          // today's bucket → dropped
            ["date": 10 * day + 3600, "value": 4.0],   // later today  → dropped
        ]
        let out = WorkoutManager.droppingCurrentDay(pts, todayStart: todayStart)
        XCTAssertEqual(dates(out), [8 * day, 9 * day])
    }

    func testKeepsEverythingWhenTodayIsInTheFuture() {
        let pts: [[String: Any]] = [["date": 1 * day], ["date": 2 * day]]
        XCTAssertEqual(WorkoutManager.droppingCurrentDay(pts, todayStart: 100 * day).count, 2)
    }

    func testEmptyStaysEmpty() {
        XCTAssertTrue(WorkoutManager.droppingCurrentDay([], todayStart: 0).isEmpty)
    }

    func testMalformedEntryWithoutDateIsDropped() {
        let pts: [[String: Any]] = [["value": 1.0], ["date": 5 * day, "value": 2.0]]
        let out = WorkoutManager.droppingCurrentDay(pts, todayStart: 10 * day)
        XCTAssertEqual(dates(out), [5 * day])
    }
}
