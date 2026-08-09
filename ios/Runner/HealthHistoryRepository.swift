import HealthKit

/// Read-only historical-HealthKit queries — everything the app asks Apple
/// Health about the PAST (workout import, readiness/daily trends, overnight
/// HRV/HR, VO₂ max, body mass, the DOB→zones profile). Extracted from
/// WorkoutManager, which now owns only the LIVE workout session and the
/// announce pipeline; nothing here touches the session, the audio graph, or
/// any mutable workout state. Authorization is requested once, app-wide, by
/// WorkoutManager.requestAuthorization — HKHealthStore permissions are
/// per-app, so this repository's own store instance sees the same grants.
final class HealthHistoryRepository {

    static let shared = HealthHistoryRepository()
    private init() {}

    private let healthStore = HKHealthStore()
    // MARK: - Apple Health workout import

    /// Workouts stored in Apple Health (any source — this app, Apple Watch,
    /// others), newest first, as light entries for the import picker. Duration
    /// filtering happens Dart-side so the threshold control re-filters
    /// instantly without another HealthKit round-trip.
    func listHealthWorkouts(completion: @escaping ([[String: Any]]) -> Void) {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: .workoutType(), predicate: nil,
                                  limit: 500, sortDescriptors: [sort]) { _, samples, _ in
            let out: [[String: Any]] = (samples as? [HKWorkout] ?? []).map { w in
                var entry: [String: Any] = [
                    "type": Self._activityKey(w.workoutActivityType),
                    "startEpoch": w.startDate.timeIntervalSince1970,
                    "endEpoch": w.endDate.timeIntervalSince1970,
                    "durationSeconds": w.duration,
                    "source": w.sourceRevision.source.name,
                ]
                if let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
                    .sumQuantity()?.doubleValue(for: .kilocalorie()) {
                    entry["kcal"] = kcal
                }
                // Walking-type distance for most workouts, cycling distance for rides.
                if let dist = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                    .sumQuantity()?.doubleValue(for: .meter()) {
                    entry["distanceMeters"] = dist
                } else if let dist = w.statistics(for: HKQuantityType(.distanceCycling))?
                    .sumQuantity()?.doubleValue(for: .meter()) {
                    entry["distanceMeters"] = dist
                }
                return entry
            }
            DispatchQueue.main.async { completion(out) }
        }
        healthStore.execute(query)
    }

    // Map HealthKit activity types onto the app's workout-type keys; anything
    // the app has no first-class type for imports as "other".
    private static func _activityKey(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .boxing:  return "boxing"
        case .cycling: return "cycling"
        case .running: return "running"
        case .walking: return "walking"
        case .hiking:  return "hiking"
        default:       return "other"
        }
    }

    /// Heart-rate samples between two instants, ascending, as
    /// [secondsFromStart, bpm] pairs — the same shape as a live session's
    /// hrTimeline, so an imported session replays in the chart identically.
    func getHeartRateSeries(startEpoch: Double, endEpoch: Double,
                            completion: @escaping ([[Double]]) -> Void) {
        let start = Date(timeIntervalSince1970: startEpoch)
        let end = Date(timeIntervalSince1970: endEpoch)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: HKQuantityType(.heartRate),
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, samples, _ in
            let unit = HKUnit.count().unitDivided(by: .minute())
            let series: [[Double]] = (samples as? [HKQuantitySample] ?? []).map { s in
                [s.startDate.timeIntervalSince(start), s.quantity.doubleValue(for: unit)]
            }
            DispatchQueue.main.async { completion(series) }
        }
        healthStore.execute(query)
    }

    // MARK: - Personal-history sample values (Plus distributions)

    /// Lean value-only history for the Plus "vs your own history" distributions:
    /// the raw sample VALUES (no timestamps, no aggregation, no sleep clustering)
    /// for the three metrics that have population reference curves, over `days`.
    /// One `HKSampleQuery` per type. These are low-cadence signals, so this is
    /// tens of milliseconds even at a 10-year window (measured) — unlike raw
    /// heart rate, which is deliberately not read here. Keys in the result:
    /// `restingHeartRate`, `hrvSDNN`, `vo2Max`.
    func getMetricSamples(days: Int, completion: @escaping ([String: Any]) -> Void) {
        let end = Date()
        let start = end.addingTimeInterval(-Double(max(1, days)) * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let vo2Unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        let specs: [(String, HKQuantityTypeIdentifier, HKUnit)] = [
            ("restingHeartRate", .restingHeartRate, HKUnit.count().unitDivided(by: .minute())),
            ("hrvSDNN", .heartRateVariabilitySDNN, HKUnit(from: "ms")),
            ("vo2Max", .vo2Max, vo2Unit),
        ]
        var out: [String: Any] = [:]
        let group = DispatchGroup()
        let lock = NSLock()
        for (key, id, unit) in specs {
            group.enter()
            let q = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let vals = (samples as? [HKQuantitySample] ?? []).map {
                    $0.quantity.doubleValue(for: unit)
                }
                lock.lock(); out[key] = vals; lock.unlock()
                group.leave()
            }
            healthStore.execute(q)
        }
        group.notify(queue: .main) { completion(out) }
    }

    // MARK: - Health profile (DOB → age → HR zones)

    // "female" / "male" / "other", or nil when not set in Health. Independent of
    // date of birth, so it's reported even when no DOB is available.
    private func _biologicalSexString() -> String? {
        guard let obj = try? healthStore.biologicalSex() else { return nil }
        switch obj.biologicalSex {
        case .female: return "female"
        case .male:   return "male"
        case .other:  return "other"
        case .notSet: return nil
        @unknown default: return nil
        }
    }

    func getHealthProfile() -> [String: Any] {
        let sex = _biologicalSexString()
        guard let dob = try? healthStore.dateOfBirthComponents(),
              let birthYear = dob.year else {
            // No DOB, but sex may still be set — pass it through.
            var unavailable: [String: Any] = ["available": false]
            if let sex = sex { unavailable["sex"] = sex }
            return unavailable
        }
        let calendar = Calendar.current
        let now = Date()
        // Birthday-accurate age: dateComponents([.year], from:to:) only counts a
        // full year once the birth month/day have passed this year, so the value
        // increments on the actual birthday rather than on Jan 1. Falls back to
        // the year difference if the DOB has no month/day to anchor it.
        let age: Int
        if let birthDate = calendar.date(from: dob),
           let years = calendar.dateComponents([.year], from: birthDate, to: now).year {
            age = years
        } else {
            age = calendar.component(.year, from: now) - birthYear
        }
        let maxHR = Int((208.0 - 0.7 * Double(age)).rounded())
        var profile: [String: Any] = [
            "available": true,
            "age": age,
            "maxHeartRate": maxHR,
            "zone1End":   Int((Double(maxHR) * 0.50).rounded()), // Zone 1 start  (50%)
            "zone2Start": Int((Double(maxHR) * 0.60).rounded()), // Zone 2 start  (60%)
            "zone3Start": Int((Double(maxHR) * 0.70).rounded()), // Zone 3 start  (70%)
            "zone4Start": Int((Double(maxHR) * 0.80).rounded()), // Zone 4 start  (80%)
            "zone5Start": Int((Double(maxHR) * 0.90).rounded()), // Zone 5 / danger (90%)
        ]
        if let sex = sex { profile["sex"] = sex }
        return profile
    }

    // MARK: - Overnight (in-bed) HRV, falling back to most recent resting HRV

    // SDNN HRV is only comparable as a resting measurement, and the cleanest
    // resting reading is overnight. We resolve the most recent night (sleep
    // onset → final wake; mid-night wake-ups included, the trailing in-bed-awake
    // period excluded) and take the MEDIAN SDNN
    // across that whole in-bed span — "bed HRV" — rather than grabbing whatever
    // the single latest sample happens to be (a daytime Breathe session or a
    // random midday stillness reading). Median, not mean, because the in-bed
    // SDNN series is spiky (movement, sleep onset) and right-skewed. With no
    // usable night — or no SDNN inside it — we fall back to the most recent
    // single sample, source "recent". The math lives in OvernightMath (tested).
    func getRecentHRV(completion: @escaping ([String: Any]?) -> Void) {
        _selectSleepNight { [weak self] night in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard let night = night else {
                self._mostRecentHRV { r in DispatchQueue.main.async { completion(r) } }
                return
            }
            self._hrvSamples(start: night.sleepOnset, end: night.bedEnd) { samples in
                let unit = HKUnit(from: "ms")
                let vals = samples.map { $0.quantity.doubleValue(for: unit) }
                // Median (not mean) — robust to the outlier SDNN samples the
                // in-bed window collects during movement / sleep onset.
                guard let value = OvernightMath.median(vals) else {
                    self._mostRecentHRV { r in DispatchQueue.main.async { completion(r) } }
                    return
                }
                DispatchQueue.main.async {
                    completion([
                        "ms": value,
                        // Out-of-bed time, so the "Xh ago" label tracks the night.
                        "timestamp": night.bedEnd.timeIntervalSince1970,
                        "source": "bed",
                        "count": vals.count,
                    ])
                }
            }
        }
    }

    // Resolves the night for bed HRV / bed HR: the most recent sleep block of at
    // least 3 h that falls within the user's normal sleeping hours (inferred from
    // recent history) — rejecting naps and odd-hour sleep. Pulls 15 days of
    // sleepAnalysis (enough to infer the habitual sleep midpoint), clusters into
    // nights, stamps each night's local time-of-day midpoint, and lets
    // OvernightMath pick. Nil when no qualifying night — the caller then falls
    // back to a single recent sample.
    private func _selectSleepNight(_ completion: @escaping (OvernightMath.Night?) -> Void) {
        _scoredNights(days: 15) { completion(OvernightMath.selectNight($0)) }
    }

    // Queries `days` of sleepAnalysis, clusters into nights, and stamps each
    // night's local time-of-day sleep-midpoint (the one piece OvernightMath
    // can't do — it needs the calendar/timezone). Shared by today's bed reading
    // (_selectSleepNight) and the daily-trends history (getBedHrvHistory).
    private func _scoredNights(days: Int,
                               _ completion: @escaping ([OvernightMath.ScoredNight]) -> Void) {
        let type = HKCategoryType(.sleepAnalysis)
        let end = Date()
        let start = end.addingTimeInterval(-Double(max(1, days)) * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            let segs = (samples as? [HKCategorySample] ?? []).map { s -> OvernightMath.Segment in
                let asleep: Bool
                if let v = HKCategoryValueSleepAnalysis(rawValue: s.value) {
                    asleep = HKCategoryValueSleepAnalysis.allAsleepValues.contains(v)
                } else {
                    asleep = false
                }
                return OvernightMath.Segment(start: s.startDate, end: s.endDate, isAsleep: asleep)
            }
            let cal = Calendar.current
            let scored: [OvernightMath.ScoredNight] = OvernightMath.clusters(segs).compactMap { cluster in
                guard let night = OvernightMath.night(from: cluster) else { return nil }
                let midEpoch = (night.sleepOnset.timeIntervalSince1970 + night.bedEnd.timeIntervalSince1970) / 2
                let mid = Date(timeIntervalSince1970: midEpoch)
                let tod = mid.timeIntervalSince(cal.startOfDay(for: mid))
                return OvernightMath.ScoredNight(night: night, midpointTOD: tod)
            }
            completion(scored)
        }
        healthStore.execute(query)
    }

    // MARK: - Readiness daily history (Plus trends hub)

    // Per-night history over the last `days` for the trends hub, as
    //   { "hrv": [{date, bedMs, sleepMs?}], "hr": [{date, bpm, sleepBpm?}],
    //     "resp": [{date, brpm}], "temp": [{date, c}], "spo2": [{date, pct}],
    //     "vo2": [{date, value}],
    //     "sleep": [{date, kind, inBedSecs, asleepSecs, hrvMs?, hrvN}] }
    // bedMs = median SDNN over the whole in-bed window; sleepMs = median SDNN over
    // the asleep segments only (the lightly-shaded overlay); bpm = mean HR over
    // the in-bed window, sleepBpm = mean HR over the asleep segments only; brpm = mean respiratory rate (breaths/min) over the
    // in-bed window (often night-only — absent nights are simply omitted).
    // Nights use the same ≥3 h / normal-hours selection as today's reading.
    // VO₂ max is independent of sleep, so it's always returned.
    func getReadinessHistory(days: Int, completion: @escaping ([String: Any]) -> Void) {
        _scoredNights(days: days) { [weak self] scored in
            guard let self = self else { DispatchQueue.main.async { completion([:]) }; return }
            let nights = OvernightMath.qualifyingNights(scored)
            // Every sleep session for the dual bar: qualifying nights tagged
            // "night", every other scored session (daytime / short) tagged
            // "nap". Naps reuse the same Night math — only the readiness
            // selection (qualifyingNights) stays night-only. Read straight off
            // each Night; no extra HealthKit query. inBedSecs = the in-bed window
            // span (movement-independent); asleepSecs = union of asleep segments.
            let sleepEntry: (OvernightMath.Night, String) -> [String: Any] = { n, kind in
                ["date": n.bedEnd.timeIntervalSince1970,
                 "kind": kind,
                 "inBedSecs": n.bedEnd.timeIntervalSince(n.sleepOnset),
                 "asleepSecs": n.asleepSeconds]
            }
            let napSessions = scored.map { $0.night }.filter { !nights.contains($0) }
            // (session, kind) in display order — nights first, then naps. Drives
            // both the durations-only fallback and the per-session HRV below.
            let kinded: [(OvernightMath.Night, String)] =
                nights.map { ($0, "night") } + napSessions.map { ($0, "nap") }
            let sleep: [[String: Any]] = kinded.map { sleepEntry($0.0, $0.1) }
            // HRV fetch span covers every session (naps included), not just nights.
            let rangeStart = kinded.map { $0.0.sleepOnset }.min()
            let rangeEnd = kinded.map { $0.0.bedEnd }.max()
            self._vo2History(days: days) { vo2 in
                guard let first = nights.first, let last = nights.last else {
                    DispatchQueue.main.async { completion(["hrv": [], "hr": [], "resp": [], "temp": [], "spo2": [], "vo2": vo2, "sleep": sleep]) }
                    return
                }
                self._hrvSamples(start: rangeStart ?? first.sleepOnset, end: rangeEnd ?? last.bedEnd) { sdnn in
                    let msUnit = HKUnit(from: "ms")
                    let sdnnPts = sdnn.map { (date: $0.startDate, ms: $0.quantity.doubleValue(for: msUnit)) }
                    // Per-session HRV for the sleep series: median SDNN + sample
                    // count over each session's in-window span (nights AND naps).
                    // The Dart side gates naps on hrvN before reporting/comparing.
                    let sleepHrv: [[String: Any]] = kinded.map { (n, kind) in
                        var e = sleepEntry(n, kind)
                        let vals = sdnnPts.filter { $0.date >= n.sleepOnset && $0.date < n.bedEnd }.map { $0.ms }
                        if let med = OvernightMath.median(vals) { e["hrvMs"] = med }
                        e["hrvN"] = vals.count
                        return e
                    }
                    var hrv: [[String: Any]] = []
                    for night in nights {
                        let bedVals = sdnnPts.filter { $0.date >= night.sleepOnset && $0.date < night.bedEnd }.map { $0.ms }
                        guard let bed = OvernightMath.median(bedVals) else { continue }
                        var e: [String: Any] = ["date": night.bedEnd.timeIntervalSince1970, "bedMs": bed]
                        let sleepVals = sdnnPts.filter { night.isAsleep(at: $0.date) }.map { $0.ms }
                        if let sleep = OvernightMath.median(sleepVals) { e["sleepMs"] = sleep }
                        hrv.append(e)
                    }
                    let rateUnit = HKUnit.count().unitDivided(by: .minute())
                    self._samplesAcross(nights: nights, type: HKQuantityType(.heartRate)) { hrSamples in
                        let hrPts = hrSamples.map { (date: $0.startDate, v: $0.quantity.doubleValue(for: rateUnit)) }
                        var hr: [[String: Any]] = []
                        for night in nights {
                            let vals = hrPts.filter { $0.date >= night.sleepOnset && $0.date < night.bedEnd }.map { $0.v }
                            guard let mean = OvernightMath.mean(vals) else { continue }
                            var e: [String: Any] = ["date": night.bedEnd.timeIntervalSince1970, "bpm": mean]
                            // Sleep HR: mean over just the asleep segments — a cleaner
                            // resting signal than the full in-bed window (mirrors sleepMs).
                            let sleepVals = hrPts.filter { night.isAsleep(at: $0.date) }.map { $0.v }
                            if let sm = OvernightMath.mean(sleepVals) { e["sleepBpm"] = sm }
                            hr.append(e)
                        }
                        // Bed respiratory rate: mean breaths/min over the in-bed
                        // window, per night (often night-only — absent nights
                        // simply don't appear, same as a no-HRV night).
                        self._samplesAcross(nights: nights, type: HKQuantityType(.respiratoryRate)) { respSamples in
                            let respPts = respSamples.map { (date: $0.startDate, v: $0.quantity.doubleValue(for: rateUnit)) }
                            var resp: [[String: Any]] = []
                            for night in nights {
                                let vals = respPts.filter { $0.date >= night.sleepOnset && $0.date < night.bedEnd }.map { $0.v }
                                if let mean = OvernightMath.mean(vals) {
                                    resp.append(["date": night.bedEnd.timeIntervalSince1970, "brpm": mean])
                                }
                            }
                            // Wrist temperature (°C) — discrete nightly sample(s),
                            // mean per night; present mainly on newer watches.
                            self._samplesAcross(nights: nights, type: HKQuantityType(.appleSleepingWristTemperature)) { tempSamples in
                                let cUnit = HKUnit.degreeCelsius()
                                let tempPts = tempSamples.map { (date: $0.startDate, v: $0.quantity.doubleValue(for: cUnit)) }
                                var temp: [[String: Any]] = []
                                for night in nights {
                                    let vals = tempPts.filter { $0.date >= night.sleepOnset && $0.date < night.bedEnd }.map { $0.v }
                                    if let mean = OvernightMath.mean(vals) {
                                        temp.append(["date": night.bedEnd.timeIntervalSince1970, "c": mean])
                                    }
                                }
                                // Overnight blood oxygen (%) — often absent
                                // (night-only; disabled on some watches), so
                                // absent nights just don't appear → empty card.
                                self._samplesAcross(nights: nights, type: HKQuantityType(.oxygenSaturation)) { spo2Samples in
                                    let pctUnit = HKUnit.percent()
                                    let spo2Pts = spo2Samples.map { (date: $0.startDate, v: $0.quantity.doubleValue(for: pctUnit) * 100) }
                                    var spo2: [[String: Any]] = []
                                    for night in nights {
                                        let vals = spo2Pts.filter { $0.date >= night.sleepOnset && $0.date < night.bedEnd }.map { $0.v }
                                        if let mean = OvernightMath.mean(vals) {
                                            spo2.append(["date": night.bedEnd.timeIntervalSince1970, "pct": mean])
                                        }
                                    }
                                    DispatchQueue.main.async {
                                        completion(["hrv": hrv, "hr": hr, "resp": resp, "vo2": vo2, "sleep": sleepHrv, "temp": temp, "spo2": spo2])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Per-calendar-day activity & heart-rate history over the last `days`, as
    //   { "steps":[{date,value}], "kcal":[...], "walkKm":[...], "walkHr":[...],
    //     "restHr":[...], "hrMax":[...], "hrMin":[...], "exMin":[...] }
    // date = the day's local midnight (epoch seconds). Cumulative sums for
    // steps/kcal/distance/exercise; daily max & min for heart rate; daily
    // average for resting & walking HR. Absent days are simply omitted.
    func getDailyHistory(days: Int, completion: @escaping ([String: Any]) -> Void) {
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: anchor) else {
            DispatchQueue.main.async { completion([:]) }; return
        }
        let interval = DateComponents(day: 1)
        let now = Date()
        let group = DispatchGroup()
        let lock = NSLock()
        var out: [String: Any] = [:]
        func record(_ key: String, _ pts: [[String: Any]]) {
            lock.lock(); out[key] = pts; lock.unlock()
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())

        // Cumulative-sum metrics: steps, active calories, walking distance, exercise minutes.
        let sums: [(String, HKQuantityType, HKUnit)] = [
            ("steps", HKQuantityType(.stepCount), HKUnit.count()),
            ("kcal", HKQuantityType(.activeEnergyBurned), HKUnit.kilocalorie()),
            ("walkKm", HKQuantityType(.distanceWalkingRunning), HKUnit.meterUnit(with: .kilo)),
            ("exMin", HKQuantityType(.appleExerciseTime), HKUnit.minute()),
        ]
        for (key, type, unit) in sums {
            group.enter()
            _dailyStats(type: type, options: .cumulativeSum, start: start, anchor: anchor, interval: interval) { stats in
                var pts: [[String: Any]] = []
                stats?.enumerateStatistics(from: start, to: now) { stat, _ in
                    if let q = stat.sumQuantity() {
                        pts.append(["date": stat.startDate.timeIntervalSince1970, "value": q.doubleValue(for: unit)])
                    }
                }
                // Drop the partial current day (pure, unit-tested helper).
                record(key, Self.droppingCurrentDay(
                    pts, todayStart: anchor.timeIntervalSince1970))
                group.leave()
            }
        }

        // Daily-average heart-rate metrics (Apple writes ~one value per day).
        // The current (incomplete) day is dropped here too — consistent with the
        // sums above: no chart or calculation uses the partial current day, so the
        // trend ends on the last finished day.
        let avgs: [(String, HKQuantityType)] = [
            ("restHr", HKQuantityType(.restingHeartRate)),
            ("walkHr", HKQuantityType(.walkingHeartRateAverage)),
        ]
        for (key, type) in avgs {
            group.enter()
            _dailyStats(type: type, options: .discreteAverage, start: start, anchor: anchor, interval: interval) { stats in
                var pts: [[String: Any]] = []
                stats?.enumerateStatistics(from: start, to: now) { stat, _ in
                    if let q = stat.averageQuantity() {
                        pts.append(["date": stat.startDate.timeIntervalSince1970, "value": q.doubleValue(for: bpm)])
                    }
                }
                record(key, Self.droppingCurrentDay(
                    pts, todayStart: anchor.timeIntervalSince1970))
                group.leave()
            }
        }

        // Heart rate: daily max + min WITH the wall-clock time each extreme
        // occurred. HKStatistics gives the value but not its timestamp, so this
        // scans the window's raw samples once and buckets by calendar day.
        group.enter()
        _dailyHrExtremes(start: start, now: now, cal: cal) { mx, mn in
            record("hrMax", mx); record("hrMin", mn); group.leave()
        }

        group.notify(queue: .main) { completion(out) }
    }

    /// Drops daily-history entries on the current (incomplete) calendar day, so a
    /// partial today never skews a trend. Pure + HealthKit-free so it's unit-
    /// testable: an entry whose "date" (epoch-seconds day-start) is on/after
    /// [todayStart] is the in-progress day and is removed; a malformed entry with
    /// no numeric date is dropped too.
    static func droppingCurrentDay(_ points: [[String: Any]],
                                   todayStart: TimeInterval) -> [[String: Any]] {
        points.filter { (($0["date"] as? Double) ?? .infinity) < todayStart }
    }

    // One daily-bucketed statistics-collection query (helper for getDailyHistory).
    private func _dailyStats(type: HKQuantityType, options: HKStatisticsOptions,
                             start: Date, anchor: Date, interval: DateComponents,
                             completion: @escaping (HKStatisticsCollection?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: options, anchorDate: anchor,
                                                intervalComponents: interval)
        query.initialResultsHandler = { _, results, _ in completion(results) }
        healthStore.execute(query)
    }

    // Daily heart-rate max & min WITH the time each extreme occurred. HKStatistics
    // exposes the value but not its timestamp, so we pull the window's raw heart-
    // rate samples once and scan them ourselves, bucketing by calendar day. Each
    // entry: {date: day start, value: bpm, at: that sample's wall-clock time}
    // (epoch seconds), oldest day first.
    private func _dailyHrExtremes(start: Date, now: Date, cal: Calendar,
                                  _ completion: @escaping (_ max: [[String: Any]], _ min: [[String: Any]]) -> Void) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let query = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            // day-start epoch -> (extreme value, time it occurred)
            var hi: [TimeInterval: (val: Double, at: TimeInterval)] = [:]
            var lo: [TimeInterval: (val: Double, at: TimeInterval)] = [:]
            for s in (samples as? [HKQuantitySample] ?? []) {
                let v = s.quantity.doubleValue(for: bpm)
                let day = cal.startOfDay(for: s.startDate).timeIntervalSince1970
                let at = s.startDate.timeIntervalSince1970
                if let cur = hi[day] { if v > cur.val { hi[day] = (v, at) } } else { hi[day] = (v, at) }
                if let cur = lo[day] { if v < cur.val { lo[day] = (v, at) } } else { lo[day] = (v, at) }
            }
            let mx = hi.keys.sorted().map { ["date": $0, "value": hi[$0]!.val, "at": hi[$0]!.at] as [String: Any] }
            let mn = lo.keys.sorted().map { ["date": $0, "value": lo[$0]!.val, "at": lo[$0]!.at] as [String: Any] }
            // Drop the partial current day (pure, unit-tested helper).
            let todayStart = cal.startOfDay(for: now).timeIntervalSince1970
            completion(Self.droppingCurrentDay(mx, todayStart: todayStart),
                       Self.droppingCurrentDay(mn, todayStart: todayStart))
        }
        healthStore.execute(query)
    }

    // VO₂ max samples over the last `days`, oldest first, as [{date, value}].
    private func _vo2History(days: Int, _ completion: @escaping ([[String: Any]]) -> Void) {
        let type = HKQuantityType(.vo2Max)
        let end = Date()
        let start = end.addingTimeInterval(-Double(max(1, days)) * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        let unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            let out = (samples as? [HKQuantitySample] ?? []).map {
                ["date": $0.endDate.timeIntervalSince1970, "value": $0.quantity.doubleValue(for: unit)]
            }
            completion(out)
        }
        healthStore.execute(query)
    }

    // Quantity samples (of `type`) restricted to the in-bed windows of `nights`
    // (an OR of per-night predicates), so we don't pull every daytime/workout
    // sample. Used for bed HR (.heartRate) and bed respiratory rate
    // (.respiratoryRate).
    private func _samplesAcross(nights: [OvernightMath.Night],
                                type: HKQuantityType,
                                _ completion: @escaping ([HKQuantitySample]) -> Void) {
        guard !nights.isEmpty else { completion([]); return }
        let preds = nights.map {
            HKQuery.predicateForSamples(withStart: $0.sleepOnset, end: $0.bedEnd, options: [.strictStartDate])
        }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: preds)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            completion(samples as? [HKQuantitySample] ?? [])
        }
        healthStore.execute(query)
    }

    // Raw SDNN samples over [start, end]; averaging is done by OvernightMath.
    private func _hrvSamples(start: Date, end: Date,
                             _ completion: @escaping ([HKQuantitySample]) -> Void) {
        let type = HKQuantityType(.heartRateVariabilitySDNN)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            completion(samples as? [HKQuantitySample] ?? [])
        }
        healthStore.execute(query)
    }

    // The single most recent SDNN sample, regardless of context — the fallback
    // when no overnight reading is available.
    private func _mostRecentHRV(_ completion: @escaping ([String: Any]?) -> Void) {
        let type = HKQuantityType(.heartRateVariabilitySDNN)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }
            let ms = sample.quantity.doubleValue(for: HKUnit(from: "ms"))
            completion([
                "ms": ms,
                "timestamp": sample.endDate.timeIntervalSince1970,
                "source": "recent",
            ])
        }
        healthStore.execute(query)
    }

    // MARK: - Overnight (in-bed) HR, falling back to most recent resting HR

    // The heart-rate analog of bed HRV: the mean heart rate across last night's
    // whole in-bed span (sleep onset → final wake; mid-night wake-ups included,
    // the trailing in-bed-awake period excluded) —
    // "bed HR". restingHeartRate is one computed value per day with nothing to
    // average over a night, so bed HR averages raw heartRate samples in the
    // window instead. With no usable night — or no HR in it — we fall back to
    // the most recent restingHeartRate sample, marked source "recent". Reuses
    // the same OvernightMath windowing as getRecentHRV.
    func getRestingHR(completion: @escaping ([String: Any]?) -> Void) {
        _selectSleepNight { [weak self] night in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard let night = night else {
                self._mostRecentRestingHR { r in DispatchQueue.main.async { completion(r) } }
                return
            }
            self._heartRateSamples(start: night.sleepOnset, end: night.bedEnd) { samples in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let vals = samples.map { $0.quantity.doubleValue(for: unit) }
                guard let mean = OvernightMath.mean(vals) else {
                    self._mostRecentRestingHR { r in DispatchQueue.main.async { completion(r) } }
                    return
                }
                DispatchQueue.main.async {
                    completion([
                        "bpm": mean,
                        // Out-of-bed time, so the "Xh ago" label tracks the night.
                        "timestamp": night.bedEnd.timeIntervalSince1970,
                        "source": "bed",
                        "count": vals.count,
                    ])
                }
            }
        }
    }

    // Raw heartRate samples over [start, end]; averaging is done by OvernightMath.
    private func _heartRateSamples(start: Date, end: Date,
                                   _ completion: @escaping ([HKQuantitySample]) -> Void) {
        let type = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            completion(samples as? [HKQuantitySample] ?? [])
        }
        healthStore.execute(query)
    }

    // The single most recent restingHeartRate sample — the fallback when no
    // overnight window is available.
    private func _mostRecentRestingHR(_ completion: @escaping ([String: Any]?) -> Void) {
        let type = HKQuantityType(.restingHeartRate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }
            let bpm = sample.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
            completion([
                "bpm": bpm,
                "timestamp": sample.endDate.timeIntervalSince1970,
                "source": "recent",
            ])
        }
        healthStore.execute(query)
    }

    // Most recent body mass (kg) from HealthKit, for the elevation energy term and
    // the "Auto" weight in Preferences.
    func getBodyMass(completion: @escaping ([String: Any]?) -> Void) {
        let type = HKQuantityType(.bodyMass)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
            DispatchQueue.main.async {
                completion(["kg": kg, "timestamp": sample.endDate.timeIntervalSince1970])
            }
        }
        healthStore.execute(query)
    }

    // MARK: - VO2 max (from Apple Watch outdoor walk/run estimate)

    func getVO2Max(completion: @escaping ([String: Any]?) -> Void) {
        let type = HKQuantityType(.vo2Max)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // mL/(kg·min) — the standard VO2 max unit
            let unit = HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
            let value = sample.quantity.doubleValue(for: unit)
            DispatchQueue.main.async {
                completion(["mlPerKgMin": value, "timestamp": sample.endDate.timeIntervalSince1970])
            }
        }
        healthStore.execute(query)
    }
}

/// Overnight-window math for the bed HRV / bed HR readings, with no HealthKit
/// or I/O dependency so it is unit-testable on the simulator (where HealthKit
/// is unavailable). The caller maps HKCategorySample → [Segment] and computes
/// each candidate night's local time-of-day midpoint (needs Calendar/timezone);
/// everything else — clustering, night selection, and the central-tendency
/// math — lives here.
///
/// A "night" is the most recent cluster that (1) holds at least `minAsleep`
/// hours of actual sleep AND (2) falls within the user's normal sleeping hours,
/// inferred from the trailing history's typical sleep midpoint. This rejects
/// short naps (rule 1) and long daytime naps (rule 2) from being mistaken for
/// the night. With too little history the inference falls back to a default
/// overnight band centered on `defaultMidpointTOD`.
enum OvernightMath {
    struct Segment {
        let start: Date
        let end: Date
        let isAsleep: Bool
    }
    struct Interval: Equatable {
        let start: Date
        let end: Date
    }
    struct Night: Equatable {
        let sleepOnset: Date     // first asleep start (a Night always has sleep)
        let bedEnd: Date         // last asleep segment end — final wake (trailing in-bed-awake excluded)
        let asleepSeconds: Double // total asleep time (overlaps merged)
        // The asleep segments, for the asleep-only "sleep HRV" series (bed HRV
        // uses the whole [sleepOnset, bedEnd] window instead).
        let asleepIntervals: [Interval]

        /// True when [date] falls inside any asleep segment of this night.
        func isAsleep(at date: Date) -> Bool {
            asleepIntervals.contains { date >= $0.start && date < $0.end }
        }
    }
    struct ScoredNight: Equatable {
        let night: Night
        let midpointTOD: Double  // local seconds-since-midnight of the sleep midpoint
    }

    private static let secondsPerDay: Double = 86400

    /// Groups segments into nights: a new night starts whenever the gap from the
    /// running cluster's end to the next segment's start exceeds `gap`. Input
    /// need not be sorted. Clusters are returned in chronological order.
    static func clusters(_ segments: [Segment], gap: TimeInterval = 3600) -> [[Segment]] {
        let sorted = segments.sorted { $0.start < $1.start }
        var result: [[Segment]] = []
        var cur: [Segment] = []
        var curEnd: Date?
        for s in sorted {
            if let e = curEnd, s.start.timeIntervalSince(e) > gap {
                result.append(cur)
                cur = []
                curEnd = nil
            }
            cur.append(s)
            curEnd = max(curEnd ?? s.end, s.end)
        }
        if !cur.isEmpty { result.append(cur) }
        return result
    }

    /// Builds a Night from one cluster: onset = first asleep start, bedEnd =
    /// last asleep segment end (the final wake — a trailing in-bed-but-awake
    /// period is excluded; mid-night wake-ups between asleep segments still fall
    /// inside the [onset, bedEnd] window), asleepSeconds = union duration of the
    /// asleep segments (overlaps merged, so two sleep-tracking sources can't
    /// double-count). Nil when the cluster has no asleep segment (e.g. only
    /// inBed recorded).
    static func night(from cluster: [Segment]) -> Night? {
        let asleep = cluster.filter { $0.isAsleep }
        guard let onset = asleep.map({ $0.start }).min() else { return nil }
        return Night(
            sleepOnset: onset,
            bedEnd: asleep.map { $0.end }.max() ?? onset,
            asleepSeconds: unionDuration(asleep.map { (start: $0.start, end: $0.end) }),
            asleepIntervals: asleep.map { Interval(start: $0.start, end: $0.end) })
    }

    /// Total covered duration of a set of intervals, with overlaps merged.
    static func unionDuration(_ intervals: [(start: Date, end: Date)]) -> Double {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return 0 }
        var total: Double = 0
        var curStart = first.start
        var curEnd = first.end
        for iv in sorted.dropFirst() {
            if iv.start > curEnd {
                total += curEnd.timeIntervalSince(curStart)
                curStart = iv.start
                curEnd = iv.end
            } else {
                curEnd = max(curEnd, iv.end)
            }
        }
        return total + curEnd.timeIntervalSince(curStart)
    }

    /// Circular mean of times-of-day (seconds in [0, 86400)). Handles the
    /// midnight wrap (e.g. mean of 23:00 and 01:00 is 00:00). Nil for empty or
    /// a degenerate antipodal set.
    static func circularMeanTOD(_ tods: [Double]) -> Double? {
        guard !tods.isEmpty else { return nil }
        let twoPi = 2 * Double.pi
        var sx = 0.0, sy = 0.0
        for tod in tods {
            let a = tod / secondsPerDay * twoPi
            sx += cos(a); sy += sin(a)
        }
        guard sx != 0 || sy != 0 else { return nil }
        var ang = atan2(sy, sx)
        if ang < 0 { ang += twoPi }
        return ang / twoPi * secondsPerDay
    }

    /// Shortest distance between two times-of-day, accounting for the wrap
    /// (23:30 → 00:30 is one hour). Range [0, 43200].
    static func circularDistanceTOD(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: secondsPerDay)
        return min(d, secondsPerDay - d)
    }

    /// All nights that qualify for bed HRV / bed HR — ≥ `minAsleep` of sleep AND
    /// a sleep midpoint within `toleranceTOD` of the user's normal sleep midpoint
    /// — sorted oldest-first. Normal midpoint is the circular mean of the
    /// long-enough nights' midpoints once there are at least `minHistoryNights`;
    /// before that, a default overnight band centered on `defaultMidpointTOD`.
    /// This is the basis for the daily-trends series; [selectNight] takes its
    /// most recent entry.
    static func qualifyingNights(
        _ scored: [ScoredNight],
        minAsleep: TimeInterval = 3 * 3600,
        toleranceTOD: Double = 4 * 3600,
        defaultMidpointTOD: Double = 3 * 3600,   // 03:00 — typical mid-sleep
        minHistoryNights: Int = 3
    ) -> [Night] {
        let longEnough = scored.filter { $0.night.asleepSeconds >= minAsleep }
        guard !longEnough.isEmpty else { return [] }
        let normalMidpoint = longEnough.count >= minHistoryNights
            ? (circularMeanTOD(longEnough.map { $0.midpointTOD }) ?? defaultMidpointTOD)
            : defaultMidpointTOD
        return longEnough
            .filter { circularDistanceTOD($0.midpointTOD, normalMidpoint) <= toleranceTOD }
            .map { $0.night }
            .sorted { $0.bedEnd < $1.bedEnd }
    }

    /// The single night for today's bed HRV / bed HR: the most recent qualifying
    /// night. Nil when nothing qualifies (caller falls back to a recent sample).
    static func selectNight(
        _ scored: [ScoredNight],
        minAsleep: TimeInterval = 3 * 3600,
        toleranceTOD: Double = 4 * 3600,
        defaultMidpointTOD: Double = 3 * 3600,
        minHistoryNights: Int = 3
    ) -> Night? {
        qualifyingNights(scored, minAsleep: minAsleep, toleranceTOD: toleranceTOD,
                         defaultMidpointTOD: defaultMidpointTOD,
                         minHistoryNights: minHistoryNights).last
    }

    /// Arithmetic mean, or nil for an empty input.
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Median, or nil for an empty input. Robust to outlier samples (movement
    /// artifacts, sleep-onset spikes), so it is preferred over `mean` for the
    /// spiky, right-skewed SDNN series collected across the in-bed window.
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        return n.isMultiple(of: 2) ? (s[n / 2 - 1] + s[n / 2]) / 2 : s[n / 2]
    }
}
