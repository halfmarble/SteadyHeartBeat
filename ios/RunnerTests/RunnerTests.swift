import AVFoundation
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

// MARK: - Render cache

/// The cache hands buffers back to the audio engine, so the two things that
/// would break audio silently are: handing back the SAME object the player is
/// already draining, and losing a buffer in the copy. A cue is often more than
/// one buffer, so a copy that drops one truncates speech mid-number.
final class RenderCacheTests: XCTestCase {

    private func buffer(_ values: [Float]) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(values.count))!
        b.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: values.count) }
        return b
    }

    func testCopyPreservesEveryBufferAndItsSamples() {
        let source = [buffer([0.1, -0.2, 0.3]), buffer([0.4, 0.5])]
        let copied = AnnounceEngine.copies(of: source)
        XCTAssertEqual(copied.count, source.count, "a dropped buffer truncates the cue")
        for (a, b) in zip(source, copied) {
            XCTAssertEqual(a.frameLength, b.frameLength)
            for i in 0..<Int(a.frameLength) {
                XCTAssertEqual(a.floatChannelData![0][i], b.floatChannelData![0][i], accuracy: 1e-6)
            }
        }
    }

    func testCopyIsNotTheSameObject() {
        let source = [buffer([0.1, 0.2])]
        let copied = AnnounceEngine.copies(of: source)
        XCTAssertFalse(copied[0] === source[0],
                       "aliasing the cached buffer lets the player mutate the cache")
        copied[0].floatChannelData![0][0] = 0.9
        XCTAssertEqual(source[0].floatChannelData![0][0], 0.1, accuracy: 1e-6,
                       "writing to the copy must not reach the original")
    }

    /// The two cue rates in use (0.48 lead, 0.40 nudge) produce different audio
    /// for the same words, so rate has to be part of the key.
    func testCacheKeySeparatesRates() {
        let a = AVSpeechUtterance(string: "142"); a.rate = 0.48
        let b = AVSpeechUtterance(string: "142"); b.rate = 0.40
        XCTAssertNotEqual(AnnounceEngine.cacheKey(a), AnnounceEngine.cacheKey(b))
        let c = AVSpeechUtterance(string: "142"); c.rate = 0.48
        XCTAssertEqual(AnnounceEngine.cacheKey(a), AnnounceEngine.cacheKey(c))
    }
}

// MARK: - Channel coverage

/// Every method Dart invokes must have a case in AppDelegate.
///
/// When it does not, nothing fails: the Dart side fire-and-forgets several of
/// these calls, so an unhandled method is simply silence. That is exactly how
/// the welcome greeting went missing — `speakGreeting` was added to the service
/// and the native class, and its channel case was later removed by an unrelated
/// edit. No compiler complained, no test failed, and the only symptom was a
/// greeting nobody heard.
///
/// A source scan, because the two sides are different languages and the
/// contract between them is a string.
final class ChannelCoverageTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ios/RunnerTests
            .deletingLastPathComponent()      // ios
            .deletingLastPathComponent()      // repo
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 1) -> Set<String> {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var out: Set<String> = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.insert(ns.substring(with: m.range(at: group)))
        }
        return out
    }

    func testEveryDartInvocationHasANativeCase() throws {
        let service = Self.repoRoot.appendingPathComponent("lib/services/workout_service.dart")
        let delegate = Self.repoRoot.appendingPathComponent("ios/Runner/AppDelegate.swift")
        let dart = try String(contentsOf: service, encoding: .utf8)
        let swift = try String(contentsOf: delegate, encoding: .utf8)

        let invoked = Self.matches(#"invoke(?:List|Map)?Method(?:<[^>]*>)?\(\s*'([A-Za-z0-9_]+)'"#, in: dart)
        XCTAssertFalse(invoked.isEmpty, "found no invocations — the scan is checking nothing")

        let handled = Self.matches(#"case "([A-Za-z0-9_]+)":"#, in: swift)
        XCTAssertFalse(handled.isEmpty, "found no native cases — the scan is checking nothing")

        // The gate engine takes anything the switch does not recognise, so a
        // method it owns is legitimately absent from AppDelegate.
        let plusOwned: Set<String> = ["setGateConfig"]
        let missing = invoked.subtracting(handled).subtracting(plusOwned).sorted()
        XCTAssertTrue(missing.isEmpty, """
            Dart invokes \(missing) with no matching case in AppDelegate.swift. \
            These fail silently — several call sites do not await the result — so \
            the symptom is a feature that simply does nothing.
            """)
    }
}

// MARK: - Spoken-cue clip coverage

/// Every string the app speaks must have a pre-rendered clip.
///
/// A cue without one does not fail: it falls through to the system voice (Ava),
/// a different voice mid-workout, and only a runtime log records it — which is how the round-timer
/// countdown, rest, climb milestones and every gated-phase cue shipped in the
/// wrong voice while `Corpus.swift` claimed to be the whole vocabulary.
///
/// A source scan, because the cue strings sit inside workout-session code that
/// cannot run on the simulator.
final class CorpusCoverageTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ios/RunnerTests
            .deletingLastPathComponent()      // ios
            .deletingLastPathComponent()      // repo
    }

    private static func read(_ path: String) -> String? {
        try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every double-quoted literal in `code`, with each `\( … )` interpolation
    /// replaced by `{}` — so `"Climbed \(Int(m)) meters"` becomes
    /// `Climbed {} meters`. Nested parentheses inside an interpolation are
    /// counted, which a regex cannot do.
    static func swiftLiterals(in code: String) -> [String] {
        var out: [String] = []
        let c = Array(code)
        var i = 0
        while i < c.count {
            guard c[i] == "\"" else { i += 1; continue }
            var s = ""
            i += 1
            while i < c.count, c[i] != "\"" {
                if c[i] == "\\", i + 1 < c.count, c[i + 1] == "(" {
                    var depth = 1
                    i += 2
                    while i < c.count, depth > 0 {
                        if c[i] == "(" { depth += 1 } else if c[i] == ")" { depth -= 1 }
                        i += 1
                    }
                    s += "{}"
                    continue
                }
                if c[i] == "\\", i + 1 < c.count { s.append(c[i + 1]); i += 2; continue }
                s.append(c[i])
                i += 1
            }
            out.append(s)
            i += 1
        }
        return out
    }

    /// Single-quoted Dart literals, `${…}` / `$name` replaced by `{}`.
    static func dartLiterals(in code: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"'((?:[^'\\]|\\.)*)'"#)
        let ns = code as NSString
        return re.matches(in: code, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
                .replacingOccurrences(of: #"\$\{[^}]*\}"#, with: "{}", options: .regularExpression)
                .replacingOccurrences(of: #"\$[A-Za-z_]\w*"#, with: "{}", options: .regularExpression)
        }
    }

    /// Every spoken template, with where it was found.
    static func spokenTemplates() throws -> [(template: String, site: String)] {
        var out: [(String, String)] = []

        // Native: the literal arguments of every speak(…) call. The gate engine's
        // own phase keys ("warmup") are arguments to exitCue/enterPhase, not
        // speech, so those calls are cut out of the line first.
        for path in ["ios/Runner/WorkoutManager.swift", "ios/Runner/Plus/GateEngine.swift"] {
            guard let code = read(path) else { continue }
            for (n, line) in code.components(separatedBy: "\n").enumerated()
            where line.contains("speak(") && !line.contains("func speak") && !line.contains("_previewSynth") {
                let spoken = line.replacingOccurrences(
                    of: #"(exitCue|enterPhase|tick)\([^)]*\)"#, with: "", options: .regularExpression)
                for lit in swiftLiterals(in: spoken) { out.append((lit, "\(path):\(n + 1)")) }
            }
        }

        // Gate cues are RETURNED, then spoken by WorkoutManager: `case "x": return …`.
        if let gates = read("ios/Runner/Plus/GateEngine.swift") {
            for (n, line) in gates.components(separatedBy: "\n").enumerated()
            where line.range(of: #"(case\s+"[a-z]+"|default)\s*:\s*return\s+"#, options: .regularExpression) != nil {
                let rhs = String(line[line.range(of: "return")!.upperBound...])
                for lit in swiftLiterals(in: rhs) {
                    out.append((lit, "ios/Runner/Plus/GateEngine.swift:\(n + 1)"))
                }
            }
        }

        // Dart: `_tts.speak('…')`, and the greeting — literals in the statement
        // that builds the text handed to speakGreeting (the lines just above it).
        if let dart = read("lib/providers/workout_provider.dart") {
            let lines = dart.components(separatedBy: "\n")
            for (n, line) in lines.enumerated() {
                if line.contains("_tts.speak(") {
                    for lit in dartLiterals(in: line) { out.append((lit, "workout_provider.dart:\(n + 1)")) }
                }
                if line.contains("speakGreeting(") {
                    for back in max(0, n - 4)..<n {
                        for lit in dartLiterals(in: lines[back]) where lit.count > 20 {
                            out.append((lit, "workout_provider.dart:\(back + 1)"))
                        }
                    }
                }
            }
        }
        return out
    }

    func testEverySpokenStringHasAClip() throws {
        let templates = try Self.spokenTemplates()
        XCTAssertGreaterThan(templates.count, 12, "the scan found almost nothing — it is checking nothing")
        XCTAssertTrue(templates.contains { $0.template.hasPrefix("Welcome to SteadyHeartBeat") },
                      "the greeting scan found no greeting — the Dart call site moved")
        // The real gate engine returns its cues; the public stub has none. When
        // the real one is present, the scan must have found every cue it returns.
        if let gates = Self.read("ios/Runner/Plus/GateEngine.swift"), gates.contains("func exitCue") {
            let found = templates.filter { $0.site.hasPrefix("ios/Runner/Plus/GateEngine.swift") }
            XCTAssertGreaterThanOrEqual(found.count, 8, "gate-cue scan found \(found.count) cues — the return pattern changed")
        }

        var missing: [String] = []
        for (template, site) in templates {
            let expanded: [String]
            switch template {
            case "{}":
                continue   // a BPM: composed by _composeBpmAnnounce, covered below
            case "Round {}":
                expanded = (1...Corpus.maxRound).map { "Round \($0)" }
            case "Climbed {} feet":
                expanded = Corpus.climbFeet.map { "Climbed \($0) feet" }
            case "Climbed {} meters":
                expanded = Corpus.climbMeters.map { "Climbed \($0) meters" }
            default:
                if template.contains("{}") {
                    missing.append("\(site): unrecognised template \"\(template)\" — add it here and to Corpus")
                    continue
                }
                expanded = [template]
            }
            for text in expanded where KokoroClips.clipIDs(for: text) == nil {
                missing.append("\(site): \"\(text)\"")
            }
        }
        XCTAssertTrue(missing.isEmpty, """
            Spoken with no pre-rendered clip, so it plays in a different voice:
            \(missing.joined(separator: "\n"))
            Add it to Corpus.swift (fixedPhrases is append-only) and render the new clips.
            """)
    }

    /// The climb clips are one per milestone, so the milestone step in
    /// WorkoutManager and the stride in Corpus must agree.
    func testClimbMilestoneStepsMatchCorpus() throws {
        let code = try XCTUnwrap(Self.read("ios/Runner/WorkoutManager.swift"))
        func step(_ name: String) -> Int? {
            guard let r = code.range(of: name + #":\s*Double\s*=\s*(\d+)"#, options: .regularExpression)
            else { return nil }
            return Int(code[r].split(separator: "=").last!.trimmingCharacters(in: .whitespaces))
        }
        XCTAssertEqual(step("_ascentAnnounceStepFeet"), Corpus.climbFeet[1] - Corpus.climbFeet[0])
        XCTAssertEqual(step("_ascentAnnounceStepMeters"), Corpus.climbMeters[1] - Corpus.climbMeters[0])
    }

    /// The round picker's cap must not exceed the rendered rounds.
    func testRoundCapWithinCorpus() throws {
        let dart = try XCTUnwrap(Self.read("lib/providers/workout_provider.dart"))
        let re = try NSRegularExpression(pattern: #"totalRounds\s*=\s*rounds\.clamp\(\s*0\s*,\s*(\d+)\s*\)"#)
        let ns = dart as NSString
        let caps = re.matches(in: dart, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        XCTAssertFalse(caps.isEmpty, "found no round clamp — the scan is checking nothing")
        for cap in caps { XCTAssertLessThanOrEqual(cap, Corpus.maxRound) }
    }

    func testEveryBpmInRangeAndTheUnclearReadingHaveClips() {
        for n in Corpus.bpmRange {
            for text in ["\(n)", "\(n),", "\(n), zone 3", "\(n), below zone 1,"] {
                XCTAssertNotNil(KokoroClips.clipIDs(for: text), text)
            }
        }
        XCTAssertNil(KokoroClips.clipIDs(for: "\(Corpus.bpmRange.lowerBound - 1)"))
        XCTAssertNil(KokoroClips.clipIDs(for: "\(Corpus.bpmRange.upperBound + 1)"))
        XCTAssertNotNil(KokoroClips.clipIDs(for: Corpus.unclearReading))
    }

    /// Out-of-range readings are replaced before any number, zone or nudge is
    /// built — including with coaching on and a target set, where a glitch
    /// would otherwise also shout "push!".
    func testOutOfRangeBpmIsReplacedBeforeComposition() {
        let bounds = [95, 114, 133, 152, 171]
        for bpm in [0, 24.49, 250.5, 300] {
            for coaching in [false, true] {
                let c = BpmCue.compose(bpm: bpm, coaching: coaching, bounds: bounds, targetZone: 3)
                XCTAssertEqual(c.lead, Corpus.unclearReading, "bpm \(bpm)")
                XCTAssertNil(c.nudge, "bpm \(bpm)")
            }
        }
        // The edges round the same way the spoken number does.
        XCTAssertEqual(BpmCue.compose(bpm: 24.5, coaching: false, bounds: [], targetZone: 0).lead, "25")
        XCTAssertEqual(BpmCue.compose(bpm: 250.49, coaching: false, bounds: [], targetZone: 0).lead, "250")
    }

    /// Everything the composer can actually produce has a clip: every lead and
    /// every nudge as AnnounceEngine renders it. The hand-written strings in
    /// testEveryBpmInRangeAndTheUnclearReadingHaveClips cannot catch the
    /// composer and the corpus drifting apart (a new zone phrase, a nudge word,
    /// the "!" that turns "push" into the rendered "push!").
    func testEveryComposedBpmCueHasAClip() {
        // Realistic zones, and zones pushed to the corpus edges so zone 0 and
        // zone 5 are reached at both ends of bpmRange.
        let boundSets = [[95, 114, 133, 152, 171], [26, 27, 28, 29, 249], []]
        var checked = 0
        var missing: [String] = []
        for bounds in boundSets {
            for coaching in [false, true] {
                for target in 0...5 {
                    for tenths in stride(from: 0, through: 3_000, by: 5) {
                        let c = BpmCue.compose(bpm: Double(tenths) / 10, coaching: coaching,
                                               bounds: bounds, targetZone: target)
                        checked += 1
                        if KokoroClips.clipIDs(for: c.lead) == nil { missing.append(c.lead) }
                        if let n = c.nudge, KokoroClips.clipIDs(for: BpmCue.nudgeUtterance(n)) == nil {
                            missing.append(BpmCue.nudgeUtterance(n))
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 20_000)
        XCTAssertTrue(missing.isEmpty, "composed cues with no clip: \(Set(missing).sorted().prefix(20))")
    }

    func testZoneBoundaries() {
        let b = [95, 114, 133, 152, 171]
        XCTAssertEqual(BpmCue.zone(forBpm: 94, bounds: b), 0)
        XCTAssertEqual(BpmCue.zone(forBpm: 94.5, bounds: b), 1)   // rounds like the spoken number
        XCTAssertEqual(BpmCue.zone(forBpm: 133, bounds: b), 3)
        XCTAssertEqual(BpmCue.zone(forBpm: 171, bounds: b), 5)
        XCTAssertEqual(BpmCue.zone(forBpm: 150, bounds: [1, 2, 3]), 0, "malformed bounds name no zone")
        let steer = BpmCue.compose(bpm: 100, coaching: true, bounds: b, targetZone: 3)
        XCTAssertEqual(steer.lead, "100, zone 1,")
        XCTAssertEqual(steer.nudge, "push")
        XCTAssertEqual(BpmCue.compose(bpm: 180, coaching: true, bounds: b, targetZone: 3).nudge, "ease off")
        XCTAssertEqual(BpmCue.compose(bpm: 140, coaching: true, bounds: b, targetZone: 3).lead, "140, zone 3")
        XCTAssertEqual(BpmCue.compose(bpm: 140, coaching: false, bounds: b, targetZone: 3).lead, "140")
    }

    /// The scan above reads LITERALS. A call site that speaks a variable, or a
    /// new file that speaks at all, yields no literal and would pass silently —
    /// the same failure the scan exists to prevent. Every call site must be
    /// one the scan reads or one listed here, with the reason it is covered.
    func testEverySpeechCallSiteIsVisibleToTheScan() throws {
        var blind: [String] = []

        // Native. Non-literal arguments that are covered elsewhere:
        //   cue / $0 / enterPhase(…)  gate-engine cues, scanned at their `return`
        //   text                     AppDelegate's MethodChannel passthrough from Dart
        let covered = #"speak\((text:\s*)?(cue\)|\$0\)|_gates\.enterPhase\(|text, force: force\))"#
        let runner = Self.repoRoot.appendingPathComponent("ios/Runner")
        let files = FileManager.default.enumerator(at: runner, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 5, "found no Swift sources — the scan is checking nothing")
        for url in files {
            let rel = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            let code = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in code.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), line.contains("speak("),
                      !line.contains("func speak"), !line.contains("_previewSynth") else { continue }
                if line.range(of: covered, options: .regularExpression) != nil { continue }
                let scanned = rel == "ios/Runner/WorkoutManager.swift" || rel == "ios/Runner/Plus/GateEngine.swift"
                let spoken = line.replacingOccurrences(
                    of: #"(exitCue|enterPhase|tick)\([^)]*\)"#, with: "", options: .regularExpression)
                if !scanned || Self.swiftLiterals(in: spoken).isEmpty {
                    blind.append("\(rel):\(n + 1): \(trimmed)")
                }
            }
            // Clip lookups outside the announce path play a named phrase directly.
            for (n, line) in code.components(separatedBy: "\n").enumerated() {
                guard let r = line.range(of: #"(fileURLs|buffers)\(for: [A-Za-z_.]+\)"#, options: .regularExpression),
                      !line.contains("func ") else { continue }
                let arg = String(line[r]).components(separatedBy: "for: ")[1].dropLast()
                if arg == "text" || arg == "utt.speechString" { continue }   // passthroughs
                guard let def = code.range(of: "let \(arg) = \"([^\"]*)\"", options: .regularExpression) else {
                    blind.append("\(rel):\(n + 1): clip lookup of \(arg), not a literal"); continue
                }
                let phrase = String(code[def]).components(separatedBy: "\"")[1]
                let ids = KokoroClips.clipIDs(for: phrase)
                if ids == nil { blind.append("\(rel):\(n + 1): \"\(phrase)\" has no clip") }
                // `.first` plays one file: a phrase stitched from several clips would be cut short.
                if line.contains(")?.first"), let ids, ids.count != 1 {
                    blind.append("\(rel):\(n + 1): \"\(phrase)\" is \(ids.count) clips but only the first plays")
                }
            }
        }

        // Dart: only workout_provider.dart speaks, and every call carries a literal.
        let lib = Self.repoRoot.appendingPathComponent("lib")
        let dartFiles = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "dart" } ?? []
        XCTAssertGreaterThan(dartFiles.count, 5, "found no Dart sources — the scan is checking nothing")
        for url in dartFiles {
            let rel = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            let code = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in code.components(separatedBy: "\n").enumerated()
            where line.range(of: #"\.(speak|speakGreeting)\("#, options: .regularExpression) != nil
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if rel != "lib/providers/workout_provider.dart" {
                    blind.append("\(rel):\(n + 1): speaks from a file the scan does not read")
                } else if line.contains("_tts.speak("), Self.dartLiterals(in: line).isEmpty {
                    blind.append("\(rel):\(n + 1): speaks a non-literal")
                }
            }
        }

        XCTAssertTrue(blind.isEmpty, """
            Speech the corpus scan cannot see:
            \(blind.joined(separator: "\n"))
            Speak a literal, extend testEverySpokenStringHasAClip to read it, \
            or list it here with the reason it is covered.
            """)
    }

    /// Every id the corpus declares was actually rendered and shipped.
    func testEveryCorpusClipIsShipped() throws {
        let dir = Self.repoRoot.appendingPathComponent("ios/Runner/KokoroAssets/KokoroClips")
        let data = try Data(contentsOf: dir.appendingPathComponent("clips.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["voice"] as? String, Corpus.defaultVoice)
        let clips = try XCTUnwrap(json["clips"] as? [String: [String: Any]])

        let all = Corpus.all()
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate clip ids in Corpus")
        var problems: [String] = []
        for (id, text) in all {
            if (clips[id]?["text"] as? String) != text { problems.append("\(id): not in clips.json with text \"\(text)\"") }
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).m4a").path) {
                problems.append("\(id).m4a missing")
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems.count) unrendered clips:\n" + problems.prefix(30).joined(separator: "\n"))
    }
}
