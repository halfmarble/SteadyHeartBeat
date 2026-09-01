import XCTest
@testable import Runner

// Unit tests for the pure, HealthKit-/engine-free logic extracted from
// WorkoutManager / HealthHistoryRepository (OvernightMath, AnnounceQueue). These run on the simulator — they
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

// HealthHistoryRepository.droppingCurrentDay — the pure rule that keeps a partial current
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
        let out = HealthHistoryRepository.droppingCurrentDay(pts, todayStart: todayStart)
        XCTAssertEqual(dates(out), [8 * day, 9 * day])
    }

    func testKeepsEverythingWhenTodayIsInTheFuture() {
        let pts: [[String: Any]] = [["date": 1 * day], ["date": 2 * day]]
        XCTAssertEqual(HealthHistoryRepository.droppingCurrentDay(pts, todayStart: 100 * day).count, 2)
    }

    func testEmptyStaysEmpty() {
        XCTAssertTrue(HealthHistoryRepository.droppingCurrentDay([], todayStart: 0).isEmpty)
    }

    func testMalformedEntryWithoutDateIsDropped() {
        let pts: [[String: Any]] = [["value": 1.0], ["date": 5 * day, "value": 2.0]]
        let out = HealthHistoryRepository.droppingCurrentDay(pts, todayStart: 10 * day)
        XCTAssertEqual(dates(out), [5 * day])
    }
}

// NoGateEngine — the free core's inert gate engine (the one the public build
// ships via the stub makeGateEngine). Every enable must stay false and every
// hook must stay a no-op: the gated branches in WorkoutManager are unreachable
// exactly as long as these hold.
final class NoGateEngineTests: XCTestCase {
    func testEverythingDisabled() {
        let e = NoGateEngine()
        XCTAssertFalse(e.warmupEnabled)
        XCTAssertFalse(e.restEnabled)
        XCTAssertFalse(e.cooldownEnabled)
    }

    func testConsumesNoMethodsEvenWithEnablingPayload() {
        let e = NoGateEngine()
        let args: [String: Any] = [
            "warmupEnabled": true, "restEnabled": true, "cooldownEnabled": true,
            "warmupTargetBpm": 120, "restTargetBpm": 110, "cooldownTargetBpm": 90,
        ]
        XCTAssertFalse(e.handle(method: "setGateConfig", arguments: args))
        // Still inert after the push attempt.
        XCTAssertFalse(e.warmupEnabled)
        XCTAssertFalse(e.restEnabled)
        XCTAssertFalse(e.cooldownEnabled)
        XCTAssertTrue(e.statusPayload(bpm: 120).isEmpty)
    }

    func testTickAdvancesImmediatelyAndSpeaksNothing() {
        let e = NoGateEngine()
        e.reset()
        XCTAssertEqual(e.enterPhase("warmup"), "")
        var spoken: [String] = []
        // Advances on the first tick (true) so a phase can never wedge, and
        // never emits a cue.
        XCTAssertTrue(e.tick(phase: "warmup", bpm: 0, speak: { spoken.append($0) }))
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertNil(e.exitCue("warmup"))
        XCTAssertNil(e.exitCue("rest"))
        XCTAssertNil(e.exitCue("cooldown"))
    }
}

// MARK: - Kokoro Core ML compute units

/// Pins the one Kokoro rule whose violation is SILENT: Core ML must never be
/// allowed to schedule a segment on the GPU.
///
/// iOS refuses GPU work from a backgrounded app
/// (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted` — 80
/// failures in 80 attempts, measured on device 2026-08-28). SteadyHeartBeat
/// speaks *while backgrounded*, so a GPU-eligible segment is not a slow cue,
/// it is a missing one — and nothing in a build, a launch, or a foreground
/// test would show it. Upstream kokoro-swift ships `.all`, which permits
/// Metal; the vendored copy asks for `.cpuAndNeuralEngine` / `.cpuOnly`
/// instead. Background of the whole decision: `ios/Runner/Kokoro/VENDOR.md`.
///
/// **Why this reads source instead of calling the code.** Both compute-unit
/// decisions sit inside methods that cannot run without the 234 MB of
/// gitignored model segments, and `MLModelConfiguration.computeUnits` is not
/// reachable from outside `SegmentedCoreMLModel` in any case. A scan is what
/// is left — the same tactic `test/fda_copy_scan_test.dart` uses on the Dart
/// side for a rule the type system cannot carry.
///
/// What it does NOT pin: which segments get the ANE and which get CPU-only.
/// That mapping is a speed choice and may legitimately change. `.all` and
/// `.cpuAndGPU` may not.
final class KokoroComputeUnitsTests: XCTestCase {

    /// The two `MLComputeUnits` cases that keep Metal out of the process.
    private static let allowed: Set<String> = ["cpuOnly", "cpuAndNeuralEngine"]

    /// Every case name, so the scan can tell "this RHS names a compute unit"
    /// from "this RHS happens to contain a dot".
    private static let everyCase: Set<String> = ["all", "cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine"]

    /// `ios/Runner/`, derived from this file's own compile-time path so the
    /// scan follows whichever checkout or worktree the tests were built from.
    private static var runnerSource: URL {
        URL(fileURLWithPath: #filePath)      // ios/RunnerTests/RunnerTests.swift
            .deletingLastPathComponent()     // ios/RunnerTests
            .deletingLastPathComponent()     // ios
            .appendingPathComponent("Runner")
    }

    private static func swiftSources() throws -> [(name: String, text: String)] {
        guard let walker = FileManager.default.enumerator(
            at: runnerSource, includingPropertiesForKeys: nil) else { return [] }
        var out: [(name: String, text: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    /// The right-hand side of every `computeUnits = …`, to end of line.
    private static func computeUnitAssignments(in text: String) -> [String] {
        matches(#"computeUnits\s*=\s*(.+)"#, in: text)
    }

    /// Which `MLComputeUnits` cases a right-hand side can produce. A ternary
    /// yields both of its arms, and both have to be allowed.
    private static func casesNamed(in rhs: String) -> Set<String> {
        Set(matches(#"\.([A-Za-z]+)"#, in: rhs).filter { everyCase.contains($0) })
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// No `computeUnits` assignment anywhere under `ios/Runner/` may permit
    /// the GPU.
    func testNoComputeUnitsAssignmentPermitsTheGPU() throws {
        let sources = try Self.swiftSources()
        XCTAssertFalse(sources.isEmpty,
                       "scanned nothing under \(Self.runnerSource.path) — this test would pass vacuously")

        var checked = 0
        for (name, text) in sources {
            for rhs in Self.computeUnitAssignments(in: text) {
                checked += 1
                let named = Self.casesNamed(in: rhs)
                XCTAssertFalse(named.isEmpty, """
                    \(name): could not read an MLComputeUnits case out of \
                    'computeUnits = \(rhs)'. If the value now comes from a \
                    variable, this scan can no longer see it — pin it at the \
                    definition instead of deleting the check.
                    """)
                for unit in named.sorted() {
                    XCTAssertTrue(Self.allowed.contains(unit), """
                        \(name): 'computeUnits = \(rhs)' permits .\(unit). \
                        Only \(Self.allowed.sorted().map { ".\($0)" }.joined(separator: ", ")) \
                        are allowed — .all and .cpuAndGPU let Core ML schedule on the GPU, \
                        and iOS refuses GPU work from a backgrounded app. This app speaks \
                        while backgrounded, so that is a silent cue mid-workout. \
                        See ios/Runner/Kokoro/VENDOR.md.
                        """)
                }
            }
        }
        XCTAssertGreaterThan(checked, 0,
                             "found no computeUnits assignments at all — has the Core ML path moved?")
    }

    /// Guards the guard: if `SegmentedCoreMLModel.swift` is renamed, moved out
    /// of `ios/Runner/`, or stops setting compute units, the scan above starts
    /// checking nothing and would go green forever.
    func testTheCoreMLModelIsActuallyBeingScanned() throws {
        let sources = try Self.swiftSources()
        guard let model = sources.first(where: { $0.name == "SegmentedCoreMLModel.swift" }) else {
            return XCTFail("""
                SegmentedCoreMLModel.swift is not under \(Self.runnerSource.path) — \
                testNoComputeUnitsAssignmentPermitsTheGPU is checking nothing.
                """)
        }
        XCTAssertFalse(Self.computeUnitAssignments(in: model.text).isEmpty, """
            SegmentedCoreMLModel.swift sets no compute units. A bare \
            MLModelConfiguration() defaults to .all, which permits the GPU.
            """)
    }

    /// A configuration created and never assigned is the same bug wearing a
    /// different hat: `MLModelConfiguration()` defaults to `.all`.
    func testEveryModelConfigurationSetsItsComputeUnits() throws {
        for (name, text) in try Self.swiftSources() {
            let configurations = Self.count(#"MLModelConfiguration\s*\("#, in: text)
            guard configurations > 0 else { continue }
            let assignments = Self.computeUnitAssignments(in: text).count
            XCTAssertGreaterThanOrEqual(assignments, configurations, """
                \(name): \(configurations) MLModelConfiguration(s) but \(assignments) \
                computeUnits assignment(s). One was left at the default, which is .all \
                — GPU-eligible, and refused in the background.
                """)
        }
    }
}
