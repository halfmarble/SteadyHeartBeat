import HealthKit
import AVFoundation
import UserNotifications
import CoreMotion

class WorkoutManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {

    static let shared = WorkoutManager()

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    // True from stopWorkout() until its async finalize clears the session — a
    // second stop during teardown would otherwise double-end the session and
    // double-finish the builder.
    private var _stopping = false
    var heartRateEventSink: FlutterEventSink?
    var statusEventSink: FlutterEventSink?
    // Status events raised while Flutter isn't subscribed yet. Used only for
    // the audio warnings: the engine can fail INSIDE startWorkout, before the
    // Dart side re-subscribes to the status stream — an unbuffered emit there
    // lands on a nil sink and the warning is lost for good.
    private var _pendingStatusEvents: [[String: Any]] = []

    /// Sets (or clears) the status sink and flushes any buffered events to a
    /// fresh sink. AppDelegate's StatusStreamHandler calls this instead of
    /// assigning `statusEventSink` directly.
    func attachStatusSink(_ sink: FlutterEventSink?) {
        statusEventSink = sink
        guard let sink, !_pendingStatusEvents.isEmpty else { return }
        let pending = _pendingStatusEvents
        _pendingStatusEvents = []
        for event in pending { sink(event) }
    }

    /// Emit-or-buffer for status events that must not be lost to a nil sink.
    private func _emitStatus(_ payload: [String: Any]) {
        if let sink = statusEventSink {
            sink(payload)
        } else {
            _pendingStatusEvents.append(payload)
        }
    }

    // The announce voice — mirrored into _announce.voice on change; also used
    // by the out-of-process preview synth (bindAirPods / previewVoice).
    private var _speechVoice: AVSpeechSynthesisVoice?

    // The in-process render → duck → play pipeline (AnnounceEngine.swift).
    // This manager keeps announce POLICY (cooldowns, boxing-countdown
    // suppression, route-loss gating, zone composition) and feeds the engine
    // plain requests; hooks are wired in init.
    private let _announce = AnnounceEngine()

    // True while the workout's Bluetooth audio route is gone (AirPods dropped
    // mid-workout). Spoken cues are suppressed while set — without this they
    // fall back to the iPhone speaker and announce heart rate out loud in
    // public. Cleared when a Bluetooth device (re)connects or a workout starts.
    private var _btRouteLost = false

    // Native-driven periodic announce. Flutter's Dart isolate is suspended when
    // the app is backgrounded, so a Dart Timer.periodic stops firing. We own
    // the periodic announce on the native side. Use DispatchSourceTimer instead
    // of NSTimer/Timer.scheduledTimer because GCD timers don't depend on the
    // main runloop being in the right mode — they fire as long as the process
    // is alive, which HKWorkoutSession guarantees while a workout is active.
    private var _latestBpm: Double = 0
    private var _announceIntervalSeconds: Double = 15
    private var _announceTimer: DispatchSourceTimer?
    // Continuous mode (interval "0"): announces run back-to-back. Instead of
    // chaining on didFinish (fragile — a didCancel from an interrupting
    // utterance breaks the chain), we run a fast poll timer that fires the next
    // announce whenever the synth is idle. Self-healing: however an utterance
    // ended, the next poll tick simply sees "not speaking" and speaks again.
    // The per-utterance BPM cooldown is bypassed in this mode.
    private var _continuousAnnounce = false
    private let _continuousPollSeconds: Double = 0.3
    // Cooldown for BPM-number announces. Without this, the Dart delta-trigger
    // fires on the first sample AND on noisy calibration samples in the first
    // few seconds — and the native periodic can also collide with Dart delta
    // within a second or two. Applies only to numeric utterances; alerts like
    // "Heart rate signal lost" always speak.
    private var _lastBpmAnnouncedAt: TimeInterval = 0
    private let _minBpmAnnounceCooldownSeconds: TimeInterval = 5
    // Timestamp of the freshest HR sample we've consumed. HKLiveWorkoutBuilder's
    // mostRecentQuantity() returns the cached last sample forever (even when
    // the sensor has gone silent), so we use the sample's own date to detect
    // whether a callback brought genuinely new data. Also used by _tickAnnounce
    // to suppress announces when the data is stale.
    private var _lastHrSampleAt: TimeInterval = 0
    private let _hrStalenessSeconds: TimeInterval = 30

    // Zone coaching. _zoneBounds holds the 5 zone-start BPMs (50/60/70/80/90% of
    // max HR), ascending, pushed from Dart at workout start. When enabled, a BPM
    // announce is enriched with the zone ("142, zone 4"); with a target zone set,
    // a steering nudge ("push" / "ease off") is appended. Enrichment happens here
    // (not Dart) so it also applies to the native background periodic announce.
    private var _zoneBounds: [Int] = []
    private var _zoneCoachingEnabled = false
    private var _targetZone = 0     // 0 = no target; 1...5

    // Boxing round timer. Native-owned (a second DispatchSourceTimer alongside
    // the announce timer) so it keeps ticking when the app is backgrounded —
    // Flutter's isolate suspends, so a Dart timer would stall mid-round. Drives a
    // prep → work → rest → done state machine, speaking a protected cue at each
    // transition ("Round 2", "Rest", "ten seconds", "Workout complete") and
    // emitting a 'round' status event each second so the foreground UI can render
    // a countdown. Started for boxing workouts when enabled; config is pushed from
    // Dart before startWorkout.
    private var _boxingEnabled = false
    private var _roundSecs = 180
    private var _restSecs = 60
    private var _totalRounds = 12      // 0 = unlimited
    private var _warnSecs = 10         // "ten seconds" cue before round end; 0 = off
    private var _prepSecs = 10         // silent get-ready countdown before round 1
    private enum RoundPhase: String { case prep, warmup, work, rest, cooldown, done }
    private var _roundPhase: RoundPhase = .done
    private var _currentRound = 0
    private var _phaseRemaining = 0    // seconds left in the current phase
    private var _roundTimer: DispatchSourceTimer?
    // BPM announces are suppressed until this time so they don't collide with a
    // boxing countdown/bell/announcement (set in _tickRound).
    private var _suppressBpmUntil: TimeInterval = 0

    // MARK: - Plus gate engine plug point
    //
    // HR-gated phases (warm-up / recovery-gated rest / cool-down) are driven by
    // the Plus module's gate engine, reached only through GateEngineProtocol
    // (declared at the bottom of this file). The implementation lives in
    // Plus/GateEngine.swift; the public free core carries a stub version of
    // that file whose engine has every enable false — the gated branches below
    // are then unreachable and the round timer behaves byte-for-byte like the
    // fixed-time boxing timer. Cue wording, targets, and pacing all live in
    // the engine, not here.
    private let _gates: GateEngineProtocol = makeGateEngine()

    // Barometric elevation (CMAltimeter). Relative altitude only — no GPS — gated
    // by NSMotionUsageDescription. Total ASCENT is accumulated with a hysteresis
    // reference so barometer jitter isn't integrated into the climb total. The
    // gravitational-work energy term is computed Dart-side (it depends on the
    // user's body-mass setting), so we only emit the raw ascent here.
    private let _altimeter = CMAltimeter()
    private var _ascentMeters: Double = 0
    private var _altRef: Double?                              // running reference for ascent
    private let _ascentThresholdMeters: Double = 1.0         // net rise before counting
    private var _lastAscentAnnounceMeters: Double = 0
    private let _ascentAnnounceStepMeters: Double = 50       // metric: announce every +50 m
    private let _ascentAnnounceStepFeet: Double = 100        // imperial: announce every +100 ft
    private let _metersPerFoot: Double = 0.3048

    // iPhone step + distance counting (CMPedometer). The HKLiveWorkoutBuilder
    // .stepCount / .distanceWalkingRunning statistics are unreliable on iPhone
    // (they're built around the Apple Watch and usually come back empty), so we
    // count steps directly off the motion coprocessor — accurate with the phone
    // in a pocket or bag, no GPS. Same NSMotionUsageDescription as the altimeter.
    private let _pedometer = CMPedometer()
    private var _steps: Double?
    private var _pedometerDistanceMeters: Double?


    private override init() {
        super.init()
        // Announce-engine hooks: zone composition, "is a workout live" for the
        // engine's own config-change recovery, and the failure signal that
        // becomes the buffered `audioUnavailable` status event.
        _announce.composeBpm = { [weak self] bpm in
            self?._composeBpmAnnounce(bpm) ?? ("\(Int(bpm.rounded()))", nil)
        }
        _announce.isActive = { [weak self] in self?.session != nil }
        _announce.voiceProvider = { [weak self] in self?._speechVoice }
        _announce.onEngineStartFailed = { [weak self] in
            self?._emitStatus(["type": "state", "value": "audioUnavailable"])
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_audioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_audioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    // iOS interrupted the audio session (phone call, alarm, Siri…).
    //   .began  — stop any in-flight utterance cleanly so the synth doesn't
    //             try to resume a half-said number when we reactivate.
    //   .ended  — reactivate the session so background TTS resumes for the next
    //             announce. We deliberately do NOT gate on .shouldResume:
    //             Apple's sample code does, but a phone call ending usually
    //             omits that flag for an app like ours that holds the session
    //             yet only speaks intermittently. Gating on it left the session
    //             deactivated after a call, and because .ended is the one moment
    //             iOS lets a *backgrounded* app reactivate, every later
    //             per-utterance setActive() (a silent try?) was denied — the
    //             user stopped hearing announcements while logging continued.
    @objc private func _audioSessionInterruption(_ note: Notification) {
        // Delivered on a system thread. The announce pipeline (queues, players,
        // engine) is main-owned, so extract the payload here and mutate on main.
        guard let userInfo = note.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        // shouldResume is informational here. When iOS already wants us to
        // resume, one attempt is enough; otherwise (the common post-call
        // case) we retry to ride out call-audio teardown still in flight.
        var shouldResume = false
        if let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
            shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.session != nil else { return }
            switch type {
            case .began:
                self._announce.flush()
            case .ended:
                self._reactivateAfterInterruption(retriesRemaining: shouldResume ? 1 : 3)
            @unknown default:
                break
            }
        }
    }

    // Reactivate the audio session after an interruption ends. The call-audio
    // route can still be tearing down at the instant .ended fires, so the first
    // setActive() may throw (e.g. error 561017449, "session activation failed").
    // Retry a few times on the main queue with a short delay to ride that out,
    // then reactivate so the next _tickAnnounce lands on a live session.
    private func _reactivateAfterInterruption(retriesRemaining: Int) {
        guard session != nil else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
        do {
            try s.setActive(true, options: [])
            // The system pauses our engine across an interruption — rebuild it so
            // the next cue lands on a live graph.
            _announce.rebuild()
        } catch {
            NSLog("SHB audio session reactivation failed (retries left \(retriesRemaining)): \(error)")
            guard retriesRemaining > 0 else {
                // Out of retries: announcements are dead for the rest of the
                // workout. Logging continues fine, so tell Flutter instead of
                // failing silently — the exact "user hears nothing and doesn't
                // know why" failure this handler exists to prevent.
                _emitStatus(["type": "state", "value": "audioUnavailable"])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?._reactivateAfterInterruption(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    // React to devices joining or leaving — NOT to app switches (which also
    // fire this notification). Activating the session on every app switch is
    // what kills music playback. Delivered on a system thread; all handling
    // hops to main (the pipeline's queue).
    @objc private func _audioSessionRouteChange(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.session != nil else { return }
            switch reason {
            case .newDeviceAvailable:
                // Only a Bluetooth output (the class of route the buds occupy)
                // clears the suppression — a wired dock / CarPlay / AirPlay
                // device appearing must NOT cause heart-rate numbers to speak
                // through shared speakers.
                let btTypes: Set<AVAudioSession.Port> =
                    [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
                let hasBt = AVAudioSession.sharedInstance().currentRoute.outputs
                    .contains { btTypes.contains($0.portType) }
                if hasBt {
                    let wasLost = self._btRouteLost
                    self._btRouteLost = false
                    self._announce.start()
                    if wasLost {
                        // Lets Dart clear the route-lost warning — and re-arms
                        // it for a second loss in the same workout (the
                        // SnackBar dedupes on the message string).
                        self._emitStatus(["type": "state", "value": "audioRouteRestored"])
                    }
                } else if !self._btRouteLost {
                    // Non-BT device while the route is healthy: preserve the
                    // old rebuild-on-new-device behavior.
                    self._announce.start()
                }
            case .oldDeviceUnavailable:
                // A device left. If no Bluetooth output remains, the system has
                // fallen back to the iPhone speaker — flush the pipeline and
                // suppress cues (speak() gates on _btRouteLost) so heart-rate
                // numbers aren't announced out loud in the room.
                let btTypes: Set<AVAudioSession.Port> =
                    [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
                let stillBt = AVAudioSession.sharedInstance().currentRoute.outputs
                    .contains { btTypes.contains($0.portType) }
                if !stillBt {
                    self._btRouteLost = true
                    self._announce.flush()
                    self._emitStatus(["type": "state", "value": "audioRouteLost"])
                }
            default:
                break
            }
        }
    }

    static func configureAudioCategory() {
        // Baseline (idle) session: .playback so audio survives backgrounding,
        // mode .voicePrompt so the cue is treated as a navigation prompt, and
        // [.mixWithOthers] so we coexist with Music WITHOUT ducking it. Ducking
        // is applied dynamically per-cue (see _playDucked) by adding .duckOthers
        // to the already-active session — the one lever that works in the
        // background, where re-activating the session is denied.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.mixWithOthers]
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Workout is continuing — speak the confirmation directly from native instead
    // of bouncing through Flutter, because Flutter's Dart isolate may be paused
    // by the time the background transition completes and the speak MethodChannel
    // call would never reach native.
    @objc private func _appDidEnterBackground() {
        guard session != nil else { return }
        speak(text: "Now monitoring in the background")
        statusEventSink?(["type": "state", "value": "backgrounded"])
    }

    // App is being killed. Flutter TTS won't process in time, so:
    //  1. Speak via native AVSpeechSynthesizer (best-effort, may be cut short by SIGKILL).
    //  2. Post a local notification — iOS delivers this after the process dies.
    @objc private func _appWillTerminate() {
        guard session != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Workout monitoring stopped"
        content.body = "SteadyHeartBeat was closed while monitoring was active. Your workout data has been saved."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "shb-terminated",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - Voice selection

    // Numeric rank for an AVSpeechSynthesisVoiceQuality so the higher tier wins
    // (Option A): premium (3) > enhanced (2) > default (1). Newer SDKs add
    // .premium; the @unknown arm keeps this exhaustive.
    private func _qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium:  return 3
        case .enhanced: return 2
        case .default:  return 1
        @unknown default: return 0
        }
    }

    private func _qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium:  return "premium"
        case .enhanced: return "enhanced"
        case .default:  return "default"
        @unknown default: return "default"
        }
    }

    private func _genderName(_ g: AVSpeechSynthesisVoiceGender) -> String {
        switch g {
        case .male:   return "male"
        case .female: return "female"
        case .unspecified: return "unspecified"
        @unknown default:  return "unspecified"
        }
    }

    // The user's preferred English language tag (e.g. "en-US"): the first English
    // entry in their ordered language preferences, else English in the device's
    // region, else en-US. Used to float locale-matching voices to the top.
    private func _preferredEnglishTag() -> String {
        for lang in Locale.preferredLanguages where lang.hasPrefix("en") {
            return lang
        }
        return "en-\(Locale.current.region?.identifier ?? "US")"
    }

    // English voices installed on THIS iPhone, ordered for the picker:
    //   1) voices in the current locale first (exact tag, then same region),
    //   2) then by quality — Apple's quality tier is also the size signal
    //      (.premium = large neural downloads, .default = compact built-ins);
    //      AVSpeechSynthesisVoice exposes no actual byte size,
    //   3) then by name.
    // A voice the user hasn't downloaded simply won't appear (Premium/Enhanced
    // voices are on-device downloads — iOS 26: Settings → Accessibility →
    // Read & Speak → Voices).
    private func _englishVoices() -> [AVSpeechSynthesisVoice] {
        let pref = _preferredEnglishTag()
        let prefRegion = Locale.current.region?.identifier.uppercased()
        func localeRank(_ v: AVSpeechSynthesisVoice) -> Int {
            if v.language.caseInsensitiveCompare(pref) == .orderedSame { return 2 }
            if let r = prefRegion, v.language.uppercased().hasSuffix("-\(r)") { return 1 }
            return 0
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted {
                let la = localeRank($0), lb = localeRank($1)
                if la != lb { return la > lb }                 // 1) current locale first
                let qa = _qualityRank($0.quality), qb = _qualityRank($1.quality)
                if qa != qb { return qa > qb }                 // 2) quality == size proxy
                return $0.name < $1.name                       // 3) name
            }
    }

    // Option A: when the user hasn't picked a specific voice, choose the highest
    // quality English voice available on the device.
    private func _bestDefaultVoice() -> AVSpeechSynthesisVoice? {
        _englishVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Select the announce voice by its system identifier. An empty/unknown
    /// identifier falls back to the best available voice (Option A).
    func setVoice(identifier: String) {
        if !identifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: identifier) {
            _speechVoice = v
        } else {
            _speechVoice = _bestDefaultVoice()
        }
    }

    /// Metadata for every installed English voice, for the picker UI.
    func listVoices() -> [[String: Any]] {
        _englishVoices().map { v in
            [
                "identifier": v.identifier,
                "name":       v.name,
                "quality":    _qualityName(v.quality),
                "gender":     _genderName(v.gender),
                "language":   v.language,
            ]
        }
    }

    /// The identifier of the voice the announce path is currently using (so the
    /// picker can highlight the resolved "best available" voice).
    func currentVoiceIdentifier() -> String {
        (_speechVoice ?? _bestDefaultVoice())?.identifier ?? ""
    }

    // Foreground-only sample playback for the picker. Uses a separate synthesizer
    // and AVSpeechSynthesizer.speak() directly — the in-process-engine dance is
    // only needed for background-over-music, which never applies in Settings. We
    // briefly take a ducking playback session so the sample is audible over Music.
    private let _previewSynth = AVSpeechSynthesizer()
    func previewVoice(identifier: String, text: String) {
        _previewSynth.stopSpeaking(at: .immediate)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
        try? s.setActive(true, options: [])
        let utt = AVSpeechUtterance(string: text)
        utt.voice = (!identifier.isEmpty ? AVSpeechSynthesisVoice(identifier: identifier) : nil)
            ?? _speechVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utt.rate = 0.48
        utt.volume = 1.0
        _previewSynth.speak(utt)
    }

    // MARK: - Zone coaching

    func setZones(_ bounds: [Int]) {
        // Expect exactly 5 ascending boundaries; ignore anything malformed.
        _zoneBounds = (bounds.count == 5) ? bounds : []
    }

    func setZoneCoaching(enabled: Bool, targetZone: Int) {
        _zoneCoachingEnabled = enabled
        _targetZone = max(0, min(5, targetZone))
    }

    // 0 = below zone 1 (under 50% max HR); 1...5 = the five training zones.
    private func _zoneNumber(forBpm bpm: Double) -> Int {
        guard _zoneBounds.count == 5 else { return 0 }
        let b = Int(bpm.rounded())
        if b < _zoneBounds[0] { return 0 }
        if b < _zoneBounds[1] { return 1 }
        if b < _zoneBounds[2] { return 2 }
        if b < _zoneBounds[3] { return 3 }
        if b < _zoneBounds[4] { return 4 }
        return 5
    }

    // Build the spoken text for a BPM number, enriched with zone coaching when on.
    // Returns the lead phrase (number + zone) and, when steering is needed, the
    // bare nudge word. The nudge is rendered as its OWN utterance and its PCM is
    // amplified in speak() — Apple's SSML <emphasis>/volume is barely audible, so
    // boosting the rendered samples is the only way to make "push"/"ease off"
    // actually hit hard instead of sounding like one more word in a list.
    private func _composeBpmAnnounce(_ bpm: Double) -> (lead: String, nudge: String?) {
        let n = Int(bpm.rounded())
        guard _zoneCoachingEnabled, _zoneBounds.count == 5 else { return ("\(n)", nil) }
        let z = _zoneNumber(forBpm: bpm)
        let zonePhrase = (z == 0 ? "below zone 1" : "zone \(z)")
        // No target, or already on target → just name the zone, no nudge.
        guard _targetZone > 0, z != _targetZone else {
            return ("\(n), \(zonePhrase)", nil)
        }
        // Trailing comma → a beat of silence before the shouted nudge lands.
        return ("\(n), \(zonePhrase),", (z < _targetZone) ? "push" : "ease off")
    }

    // MARK: - Boxing round timer

    func setBoxingRounds(enabled: Bool, roundSecs: Int, restSecs: Int,
                         totalRounds: Int, warnSecs: Int, prepSecs: Int) {
        _boxingEnabled = enabled
        _roundSecs = max(1, roundSecs)
        _restSecs = max(0, restSecs)
        _totalRounds = max(0, totalRounds)
        _warnSecs = max(0, warnSecs)
        _prepSecs = max(0, prepSecs)
    }

    // Offers a method-channel call the core doesn't recognize to the Plus
    // module (e.g. its gate-config push). Returns true when consumed; the
    // free core's stub engine consumes nothing.
    func handlePlusMethod(_ method: String, arguments: Any?) -> Bool {
        _gates.handle(method: method, arguments: arguments)
    }

    private func _startRoundTimer() {
        _stopRoundTimer()
        guard _boxingEnabled else { return }
        _gates.reset()
        _currentRound = 0
        if _gates.warmupEnabled {
            // HR-gated warm-up precedes round 1 (supersedes the silent prep countdown).
            _enterGatedPhase(.warmup)
        } else if _prepSecs > 0 {
            _roundPhase = .prep
            _phaseRemaining = _prepSecs
        } else {
            _enterWork()   // straight into round 1
        }
        _emitRound()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?._tickRound() }
        timer.resume()
        _roundTimer = timer
    }

    private func _stopRoundTimer() {
        _roundTimer?.cancel()
        _roundTimer = nil
        _roundPhase = .done
    }

    private func _tickRound() {
        guard _roundPhase != .done else { return }

        // Gated phases (warm-up / recovery-gated rest / cool-down) advance on heart
        // rate, not a countdown. The engine emits its own escalating HR cue.
        if _isInGatedPhase {
            if _gates.tick(phase: _roundPhase.rawValue, bpm: _latestBpm,
                           speak: { [weak self] in self?.speak(text: $0) }) {
                _advanceRound()
            }
            _emitRound()
            return
        }

        _phaseRemaining -= 1
        // Hold off BPM announces around the countdown + bell/announcement so they
        // don't collide with "3,2,1 → bell → ROUND X / REST". Covers the 3 s
        // countdown plus ~4 s for the bell + spoken transition that follows.
        if _phaseRemaining <= 3 {
            _suppressBpmUntil = Date().timeIntervalSinceReferenceDate + 4.0
        }
        if _roundPhase == .work, _warnSecs > 0, _phaseRemaining == _warnSecs {
            speak(text: "ten seconds")
        }
        // Spoken final-seconds countdown into every transition (prep→round 1,
        // round→rest, rest→next round). Spelled as words, not digits, so speak()
        // doesn't mistake them for a BPM number and route them through the BPM
        // cooldown/interrupt path — they ride the protected (non-BPM) cue path.
        if (1...3).contains(_phaseRemaining) {
            speak(text: ["one", "two", "three"][_phaseRemaining - 1])
        }
        if _phaseRemaining <= 0 {
            _advanceRound()
        }
        _emitRound()
    }

    private func _enterWork() {
        _currentRound += 1
        _roundPhase = .work
        _phaseRemaining = _roundSecs
        speak(text: "Round \(_currentRound)", withBell: true)
    }

    private func _advanceRound() {
        switch _roundPhase {
        case .prep:
            _enterWork()
        case .warmup:
            // Warm-up reached the work band (or capped) → round 1.
            if let cue = _gates.exitCue("warmup") { speak(text: cue) }
            _enterWork()
        case .work:
            // 0 = unlimited, so it never reaches the finish.
            if _totalRounds > 0 && _currentRound >= _totalRounds {
                if _gates.cooldownEnabled {
                    _enterGatedPhase(.cooldown)
                } else {
                    speak(text: "Workout complete", withBell: true)
                    _stopRoundTimer()   // sets phase = .done
                }
            } else if _gates.restEnabled {
                _enterGatedPhase(.rest)
            } else if _restSecs > 0 {
                _roundPhase = .rest
                _phaseRemaining = _restSecs
                speak(text: "Rest", withBell: true)
            } else {
                _enterWork()        // no rest configured → next round immediately
            }
        case .rest:
            // A gated rest that hit its cap → tell the user before the next round.
            if _gates.restEnabled, let cue = _gates.exitCue("rest") {
                speak(text: cue)
            }
            _enterWork()
        case .cooldown:
            speak(text: _gates.exitCue("cooldown") ?? "Workout complete", withBell: true)
            _stopRoundTimer()
        case .done:
            break
        }
    }

    private func _emitRound() {
        var payload: [String: Any] = [
            "type": "round",
            "phase": _roundPhase.rawValue,
            "round": _currentRound,
            "total": _totalRounds,
            "remaining": max(0, _phaseRemaining),
        ]
        // During a gated phase, the engine adds the HR-gate fields so the
        // foreground UI can render the gate panel (target / current / elapsed /
        // cap) instead of a countdown.
        if _isInGatedPhase {
            payload.merge(_gates.statusPayload(bpm: _latestBpm)) { _, new in new }
        }
        statusEventSink?(payload)
    }

    // MARK: - Plus gated-phase seams

    // True while the current phase advances on heart rate (engine-driven)
    // rather than a countdown. Always false with the free core's stub engine.
    private var _isInGatedPhase: Bool {
        _roundPhase == .warmup || _roundPhase == .cooldown
            || (_roundPhase == .rest && _gates.restEnabled)
    }

    // Enter a gated phase: the engine resets its clocks and supplies the
    // opening cue.
    private func _enterGatedPhase(_ phase: RoundPhase) {
        _roundPhase = phase
        speak(text: _gates.enterPhase(phase.rawValue))
    }



    func speak(text: String, withBell: Bool = false, force: Bool = false) {
        guard !text.isEmpty else { return }
        // BPM-number announces are rate-limited so the Dart delta-trigger
        // (which fires on the first sample) doesn't double up with noisy
        // calibration samples or the native periodic. Alerts like "Heart rate
        // signal lost" — i.e., utterances that contain anything but digits —
        // always speak.
        let isBpmAnnounce = text.allSatisfy { $0.isNumber }
        if force {
            // Preference-change feedback: the user just changed an announce
            // setting and expects to hear the result right away — typically
            // seconds after a regular announcement, exactly when the cooldown
            // would swallow it. Skip cooldown + countdown suppression, but
            // still stamp the cooldown so the next timed/delta announce
            // doesn't double up right behind this one.
            if isBpmAnnounce {
                _lastBpmAnnouncedAt = Date().timeIntervalSinceReferenceDate
            }
        } else {
            // Suppress BPM announces during a boxing countdown/bell/announcement
            // so they don't talk over "3,2,1 → bell → ROUND X / REST".
            if isBpmAnnounce && Date().timeIntervalSinceReferenceDate < _suppressBpmUntil {
                return
            }
            // Continuous mode runs announces back-to-back, so the BPM cooldown
            // (which exists to de-dupe the timed/delta paths) must not apply there.
            if isBpmAnnounce && !_continuousAnnounce {
                let now = Date().timeIntervalSinceReferenceDate
                // Cap the cooldown just under the announce interval so a short
                // interval (e.g. 2s) isn't throttled by the default 5s cooldown —
                // the cooldown only needs to suppress a timed/delta double-announce,
                // not the user's chosen cadence. The 0.5s margin absorbs timer jitter
                // so a tick firing a hair early still announces.
                let cooldown = min(_minBpmAnnounceCooldownSeconds, _announceIntervalSeconds - 0.5)
                if cooldown > 0 && (now - _lastBpmAnnouncedAt) < cooldown {
                    return
                }
                _lastBpmAnnouncedAt = now
            }
        }
        // _btRouteLost: the Bluetooth route dropped mid-workout — a cue now
        // would play on the iPhone speaker and announce heart rate out loud.
        guard _announce.isRunning, !_btRouteLost else { return }
        _announce.enqueue(text: text, withBell: withBell, isBpm: isBpmAnnounce)
    }



    func stopSpeaking() {
        _announce.flush()
    }

    // MARK: - Periodic announce

    func setAnnounceInterval(seconds: Int) {
        // Always run interval + timer changes on the main queue — the same
        // queue the DispatchSourceTimer fires on — so a timer tick can't
        // interleave with a restart. MethodChannel callbacks already land on
        // main in practice, but the explicit dispatch makes the guarantee
        // local rather than depending on Flutter's threading model.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self._continuousAnnounce = (seconds <= 0)
            if !self._continuousAnnounce {
                self._announceIntervalSeconds = Double(max(1, seconds))
            }
            // (Re)start the timer at the new cadence if a workout is live. Gate
            // on the session, not "_announceTimer != nil", so a mode switch
            // mid-workout always reschedules at the right period.
            if self.session != nil {
                self._startAnnounceTimer()
            }
        }
    }

    private func _startAnnounceTimer() {
        _stopAnnounceTimer()
        // Continuous mode polls fast and gates on isSpeaking (see _tickAnnounce)
        // so announces run back-to-back; timed mode fires at the chosen period.
        let period = _continuousAnnounce ? _continuousPollSeconds : _announceIntervalSeconds
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler { [weak self] in
            self?._tickAnnounce()
        }
        timer.resume()
        _announceTimer = timer
    }

    private func _stopAnnounceTimer() {
        _announceTimer?.cancel()
        _announceTimer = nil
    }

    private func _tickAnnounce() {
        guard _latestBpm > 0, session != nil else { return }
        // Gated phases own the HR announce (the engine's escalating cadence); stay
        // quiet here so the periodic doesn't double up with the gate's cue.
        if _isInGatedPhase { return }
        // Continuous mode polls frequently; don't pile utterances on top of one
        // another — wait for the current one to finish. (The player itself stays
        // in the "playing" state between cues now, so gate on the pipeline's own
        // busy flags, not _ttsPlayer.isPlaying.)
        if _continuousAnnounce && _announce.isBusy { return }
        // Suppress announce if the cached BPM hasn't been refreshed within the
        // staleness window — the Dart side will speak "Heart rate signal lost"
        // separately via its own silence timer; we just go quiet here so the
        // user doesn't hear a stale BPM on top of (or instead of) that alert.
        let now = Date().timeIntervalSinceReferenceDate
        if (now - _lastHrSampleAt) > _hrStalenessSeconds { return }
        // NOTE: we deliberately do NOT bail on secondaryAudioShouldBeSilencedHint
        // here. That hint goes true while Apple Music plays, and bailing on it is
        // exactly what silenced BPM announces during background music — yet the
        // "Forced to background" utterance (which skips this path) ducked Music
        // and spoke fine. We're a nav-style app that ducks OVER music, so we
        // announce regardless of the hint. (Real interruptions like Siri are
        // handled via the interruption notification, which stops speech.)
        speak(text: "\(Int(_latestBpm.rounded()))")
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool, String?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, "HealthKit is not available on this device.")
            return
        }
        // Notification permission is requested separately (see
        // requestNotificationPermission) so the user isn't ambushed with two
        // unrelated permission dialogs in a row when they tap Start.
        let typesToShare: Set<HKSampleType> = [HKQuantityType.workoutType()]
        let typesToRead: Set<HKObjectType> = [
            // Read workouts back for the Apple Health import (session recovery).
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.vo2Max),
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.flightsClimbed),
            HKQuantityType(.bodyMass),
            HKQuantityType(.appleSleepingWristTemperature),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.walkingHeartRateAverage),
            // Sleep windows scope the overnight-HRV average (see getRecentHRV).
            HKCategoryType(.sleepAnalysis),
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
        ]
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            DispatchQueue.main.async { completion(success, error?.localizedDescription) }
        }
    }

    // MARK: - Notifications

    /// Triggers the system notification permission prompt. Called from
    /// Preferences when the user opts in explicitly — never bundled with
    /// HealthKit auth at workout-start time.
    func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Returns the current notification authorization status as a string the
    /// Dart side can compare against: notDetermined / denied / authorized /
    /// provisional / ephemeral.
    func getNotificationStatus(completion: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .notDetermined: status = "notDetermined"
            case .denied:        status = "denied"
            case .authorized:    status = "authorized"
            case .provisional:   status = "provisional"
            case .ephemeral:     status = "ephemeral"
            @unknown default:    status = "unknown"
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    // MARK: - Workout session

    func startWorkout(type: String = "other", announceIntervalSeconds: Int = 15, completion: @escaping (Bool, String?) -> Void) {
        // Re-entrancy guard: a second start while a session exists would
        // overwrite `session`/`builder` and leak a live HKWorkoutSession that
        // never ends.
        guard session == nil else {
            completion(false, "A workout is already active.")
            return
        }
        if _stopping {
            // The previous stop's async HealthKit finalize is still in flight
            // (saving to Health can take over a second). A quick stop → start —
            // common between interval sets — used to work by overwriting the
            // old session; now that overwriting is guarded, wait the teardown
            // out instead of failing the start.
            _startAfterTeardown(attemptsLeft: 40, type: type,
                                announceIntervalSeconds: announceIntervalSeconds,
                                completion: completion)
            return
        }
        let config = HKWorkoutConfiguration()
        switch type {
        case "boxing":
            config.activityType = .boxing
            config.locationType = .indoor
        case "cycling":
            config.activityType = .cycling
            config.locationType = .indoor
        case "running":
            config.activityType = .running
            config.locationType = .outdoor
        case "walking":
            config.activityType = .walking
            config.locationType = .outdoor
        case "hiking":
            config.activityType = .hiking
            config.locationType = .outdoor
        default:
            config.activityType = .other
            config.locationType = .unknown
        }

        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            builder = session?.associatedWorkoutBuilder()
        } catch {
            completion(false, error.localizedDescription)
            return
        }

        session?.delegate = self
        builder?.delegate = self
        builder?.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: config
        )

        // Activate the session and start the audio engine while we're still in the
        // foreground — iOS won't let a backgrounded app activate a fresh session,
        // and the held-active engine is what keeps the announce alive in the
        // background and lets us duck Music over AirPods.
        _announce.start()
        // Immediate confirmation that monitoring is live — also warms up the engine
        // so the first BPM cue plays without first-render latency. Synthesized live
        // in the user's chosen voice (no pre-recorded clips).
        speak(text: "Monitoring heart rate")

        _latestBpm = 0
        _lastHrSampleAt = 0
        _lastBpmAnnouncedAt = 0
        _btRouteLost = false   // AirPods presence was just verified by the start flow
        _startAltimeter()
        _startPedometer()
        // Apply the requested cadence before starting the timer so the first
        // announces fire at the user's interval rather than the default.
        _continuousAnnounce = (announceIntervalSeconds <= 0)
        if !_continuousAnnounce {
            _announceIntervalSeconds = Double(max(1, announceIntervalSeconds))
        }
        // Starts a periodic timer in timed mode, or a fast poll in continuous
        // mode (_startAnnounceTimer picks the period). Ticks are no-ops until
        // the first HR sample arrives (_tickAnnounce guards on _latestBpm).
        _startAnnounceTimer()

        // Boxing round timer runs alongside the announce timer. Config was pushed
        // from Dart (setBoxingRounds) before this call; it self-gates on
        // _boxingEnabled, so non-boxing or disabled just no-ops.
        if type == "boxing" { _startRoundTimer() }

        let startDate = Date()
        session?.startActivity(with: startDate)
        builder?.beginCollection(withStart: startDate) { [weak self] success, error in
            DispatchQueue.main.async {
                if !success, let self = self {
                    // Partial start: tear the half-built session down so the
                    // next start doesn't hit the re-entrancy guard forever (and
                    // the failed session/builder don't leak). Mirrors
                    // stopWorkout's finalize, including releasing the audio
                    // session so other apps get their resume signal — but skips
                    // discardWorkout: collection never began, and the builder
                    // is released with the reference. No workout was written.
                    self._stopAnnounceTimer()
                    self._stopRoundTimer()
                    self._announce.stop()
                    self._stopAltimeter()
                    self._stopPedometer()
                    self.session?.end()
                    self.session = nil
                    self.builder = nil
                    try? AVAudioSession.sharedInstance().setActive(
                        false, options: .notifyOthersOnDeactivation)
                }
                completion(success, error?.localizedDescription)
            }
        }
    }

    // Polls (main queue, 0.25 s) until the previous stop's finalize clears
    // `_stopping`, then starts; gives up after ~10 s. If another start won the
    // race meanwhile, reports "already active" like the plain guard.
    private func _startAfterTeardown(attemptsLeft: Int, type: String,
                                     announceIntervalSeconds: Int,
                                     completion: @escaping (Bool, String?) -> Void) {
        if !_stopping {
            if session == nil {
                startWorkout(type: type,
                             announceIntervalSeconds: announceIntervalSeconds,
                             completion: completion)
            } else {
                completion(false, "A workout is already active.")
            }
            return
        }
        guard attemptsLeft > 0 else {
            completion(false, "The previous workout is still finishing — try again in a moment.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?._startAfterTeardown(attemptsLeft: attemptsLeft - 1, type: type,
                                      announceIntervalSeconds: announceIntervalSeconds,
                                      completion: completion)
        }
    }

    // Whether a finished workout is persisted to HealthKit — where it counts
    // toward the Apple Fitness rings and follows the user's iCloud Health sync —
    // or discarded so it never leaves the device. Pushed from Dart at workout
    // start (and on toggle); defaults to true (save) to match the shipped UI.
    private var _saveToHealth = true

    func setSaveToHealth(_ enabled: Bool) {
        _saveToHealth = enabled
    }

    // Unit preference, pushed from Dart at workout start and on toggle (defaults
    // to the shipped UI's Imperial). Only the spoken ascent cue consumes it —
    // every on-screen value is formatted Dart-side via fmtElevation/fmtDist.
    private var _useImperial = true

    func setUseImperial(_ enabled: Bool) {
        _useImperial = enabled
    }

    func stopWorkout() {
        // Idempotency: a second stop (Dart race between stop() and the native
        // 'stopped' status event) would end an already-ended session and
        // double-finish the builder.
        guard session != nil, !_stopping else { return }
        _stopping = true
        _stopAnnounceTimer()
        _stopRoundTimer()
        _announce.stop()
        _stopAltimeter()
        _stopPedometer()
        _latestBpm = 0
        _lastHrSampleAt = 0
        _lastBpmAnnouncedAt = 0
        session?.end()
        builder?.endCollection(withEnd: Date()) { [weak self] _, error in
            guard let self = self else { return }
            if let error { NSLog("SHB endCollection failed: \(error)") }
            let finalize: () -> Void = { [weak self] in
                DispatchQueue.main.async {
                    self?.builder = nil
                    self?.session = nil
                    self?._stopping = false
                    try? AVAudioSession.sharedInstance().setActive(
                        false, options: .notifyOthersOnDeactivation
                    )
                }
            }
            if self._saveToHealth {
                self.builder?.finishWorkout { _, error in
                    if let error {
                        NSLog("SHB finishWorkout failed — workout not saved to Health: \(error)")
                    }
                    finalize()
                }
            } else {
                // Discard so nothing is written to HealthKit (and nothing syncs
                // out via iCloud Health). Any heart-rate samples the system
                // collects from the AirPods are separate and outside our control.
                self.builder?.discardWorkout()
                finalize()
            }
        }
    }


    // MARK: - Elevation (barometric ascent)

    private func _startAltimeter() {
        _ascentMeters = 0
        _altRef = nil
        _lastAscentAnnounceMeters = 0
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        _altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            self._onAltitude(data.relativeAltitude.doubleValue)
        }
    }

    private func _stopAltimeter() {
        _altimeter.stopRelativeAltitudeUpdates()
        _altRef = nil
    }

    // Count steps (and a stride-based distance estimate) off the motion
    // coprocessor for the workout's duration. CMPedometer delivers on a private
    // background queue, so state mutation and the event emit hop to main —
    // matching the rest of the event pipeline. No-op if the device can't count
    // steps, in which case the payload falls back to the workout builder.
    private func _startPedometer() {
        _steps = nil
        _pedometerDistanceMeters = nil
        guard CMPedometer.isStepCountingAvailable() else { return }
        _pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            DispatchQueue.main.async {
                let steps = data.numberOfSteps.doubleValue
                self._steps = steps
                if CMPedometer.isDistanceAvailable(), let dist = data.distance {
                    self._pedometerDistanceMeters = dist.doubleValue
                }
                self.heartRateEventSink?(["steps": steps])
            }
        }
    }

    private func _stopPedometer() {
        _pedometer.stopUpdates()
        _steps = nil
        _pedometerDistanceMeters = nil
    }

    // Accumulate total ascent from the relative-altitude stream using a hysteresis
    // reference: count a rise only once it clears the threshold above the running
    // reference (rejecting barometer jitter), and lower the reference on any dip so
    // the next genuine climb is measured from the valley. Emits the running ascent
    // and its gravitational work, and announces each +50 m milestone (native, so it
    // fires while backgrounded).
    private func _onAltitude(_ altitude: Double) {
        guard let ref = _altRef else { _altRef = altitude; return }
        if altitude > ref + _ascentThresholdMeters {
            _ascentMeters += altitude - ref
            _altRef = altitude
        } else if altitude < ref {
            _altRef = altitude
        } else {
            return   // within the band — nothing to report
        }

        heartRateEventSink?(["ascentMeters": _ascentMeters])

        // Milestone cue in the user's chosen unit. The step is a round number in
        // that unit (every +50 m / +100 ft); _useImperial is pushed from Dart and
        // read live so toggling units mid-workout takes effect on the next climb.
        let step = _useImperial ? _ascentAnnounceStepFeet * _metersPerFoot
                                 : _ascentAnnounceStepMeters
        if _ascentMeters - _lastAscentAnnounceMeters >= step {
            _lastAscentAnnounceMeters = (_ascentMeters / step).rounded(.down) * step
            if _useImperial {
                let feet = Int((_lastAscentAnnounceMeters / _metersPerFoot).rounded())
                speak(text: "Climbed \(feet) feet")
            } else {
                speak(text: "Climbed \(Int(_lastAscentAnnounceMeters)) meters")
            }
        }
    }

    // MARK: - AirPods detection via audio route

    func checkAirPodsInfo() -> [String: Any] {
        // Idle probe: activating the session makes currentRoute report accurately.
        // During a live workout the session is already active and held by the
        // announce engine — re-activating from a status query would fight the
        // engine's category/duck state, so skip it.
        if self.session == nil {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let session = AVAudioSession.sharedInstance()
        let btTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]

        // Active audio output on this iPhone right now
        if let output = session.currentRoute.outputs.first(where: { btTypes.contains($0.portType) }) {
            return ["connected": true, "activeOnThisDevice": true, "name": output.portName]
        }

        // Paired and in range but audio is routing to another device (Mac/iPad)
        if let input = session.availableInputs?.first(where: { btTypes.contains($0.portType) }) {
            return ["connected": true, "activeOnThisDevice": false, "name": input.portName]
        }

        return ["connected": false, "activeOnThisDevice": false, "name": ""]
    }

    // Try to pull the AirPods audio route — and the heart-rate binding that
    // follows it — onto THIS iPhone, without making the user open Music. The
    // mechanism is the same as the manual "play any song" fix: a device that
    // starts producing audio grabs the AirPods route. So we speak a short cue
    // through our own session, then poll the route until it flips here (or give
    // up after a short window). Returns whether the AirPods ended up active here.
    //
    // Runs in the foreground only (called from start()), where setActive(true)
    // succeeds and speech isn't null-routed — the background null-routing problem
    // documented elsewhere doesn't apply here.
    func bindAirPods(completion: @escaping (Bool) -> Void) {
        // Already here? Nothing to do.
        if (checkAirPodsInfo()["activeOnThisDevice"] as? Bool) == true {
            completion(true)
            return
        }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? s.setActive(true, options: [])
        // Nudge the route explicitly when the buds are an available input.
        if let port = s.availableInputs?.first(where: {
            [.bluetoothHFP, .bluetoothLE].contains($0.portType)
        }) {
            try? s.setPreferredInput(port)
        }

        let utt = AVSpeechUtterance(string: "Connecting to your AirPods. Please stand by.")
        utt.voice = _speechVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utt.rate = 0.48
        utt.volume = 1.0
        _previewSynth.speak(utt)

        // Poll up to ~6s for the route to switch here. Freshly-inserted buds can
        // take a couple seconds to complete the Bluetooth audio handshake once
        // our session starts producing sound, so give them room.
        _pollAirPodsBound(attemptsLeft: 12, completion: completion)
    }

    private func _pollAirPodsBound(attemptsLeft: Int, completion: @escaping (Bool) -> Void) {
        if (checkAirPodsInfo()["activeOnThisDevice"] as? Bool) == true {
            // Route is here — but don't hand control back to the start sequence
            // (which immediately speaks "Monitoring heart rate" through the audio
            // engine) until the out-of-process "Connecting…" cue has finished.
            // The two run on different synthesizers / audio paths, so the engine's
            // cue serialization can't see the preview synth — without this gate
            // the two phrases overlap and talk over each other.
            _waitForPreviewIdle { completion(true) }
            return
        }
        guard attemptsLeft > 0 else {
            // Gave up waiting for the route — silence any lingering cue so it
            // can't overlap whatever speaks next, then report failure.
            _previewSynth.stopSpeaking(at: .immediate)
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?._pollAirPodsBound(attemptsLeft: attemptsLeft - 1, completion: completion)
        }
    }

    // Poll until the foreground preview synthesizer goes idle (bounded ~5s), so a
    // cue spoken through it finishes before the engine path speaks next.
    private func _waitForPreviewIdle(attemptsLeft: Int = 25, _ done: @escaping () -> Void) {
        if !_previewSynth.isSpeaking || attemptsLeft <= 0 {
            _previewSynth.stopSpeaking(at: .immediate)
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?._waitForPreviewIdle(attemptsLeft: attemptsLeft - 1, done)
        }
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        DispatchQueue.main.async {
            switch toState {
            case .running:  self.statusEventSink?(["type": "state", "value": "running"])
            case .ended:
                self.statusEventSink?(["type": "state", "value": "stopped"])
                // System-initiated end (background kill, HealthKit timeout):
                // nothing else tears this session down — Dart's 'stopped'
                // handler deliberately skips stopWorkout(). Run the teardown
                // here so `session` is cleared and the next start isn't
                // rejected by the re-entrancy guard. stopWorkout() no-ops when
                // this .ended came from a user stop (_stopping is set).
                if !self._stopping { self.stopWorkout() }
            case .paused:   self.statusEventSink?(["type": "state", "value": "paused"])
            default: break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.statusEventSink?(["type": "error", "value": error.localizedDescription])
        }
    }

    // MARK: - HKLiveWorkoutBuilderDelegate

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        // HealthKit fires this on its own queue, but the announce state it
        // updates (_latestBpm / _lastHrSampleAt) is read by the main-queue
        // announce and round timers — hop to main so those never race. The
        // builder's statistics are safe to read from any thread.
        DispatchQueue.main.async { [weak self] in
            self?._collectLiveStats(from: workoutBuilder)
        }
    }

    private func _collectLiveStats(from workoutBuilder: HKLiveWorkoutBuilder) {
        var payload: [String: Any] = [:]

        if let stats = workoutBuilder.statistics(for: HKQuantityType(.heartRate)),
           let quantity = stats.mostRecentQuantity(),
           let interval = stats.mostRecentQuantityDateInterval() {
            let bpm = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
            let sampleAt = interval.end.timeIntervalSinceReferenceDate
            // Only forward and cache if this sample is newer than the last we
            // saw — otherwise we're just re-reading the cached stale value
            // (AirPods dropped, ear-tip lost contact, etc.) and re-announcing
            // it would mask the silence from the user.
            if bpm > 0 && sampleAt > _lastHrSampleAt {
                _latestBpm = bpm
                _lastHrSampleAt = sampleAt
                payload["bpm"] = bpm
            }
        }

        if let stats = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned)),
           let kcal = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) {
            payload["kcal"] = kcal
        }

        if let stats = workoutBuilder.statistics(for: HKQuantityType(.respiratoryRate)),
           let rr = stats.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) {
            payload["respiratoryRate"] = rr
        }

        // Steps: prefer the CMPedometer count (reliable on iPhone); fall back to
        // the workout builder's, which iPhone usually leaves empty.
        if let steps = _steps {
            payload["steps"] = steps
        } else if let stats = workoutBuilder.statistics(for: HKQuantityType(.stepCount)),
                  let steps = stats.sumQuantity()?.doubleValue(for: .count()) {
            payload["steps"] = steps
        }

        // Distance likewise prefers the pedometer's stride estimate (still not
        // GPS-accurate, but better than the builder's empty/near-zero value).
        if let dist = _pedometerDistanceMeters {
            payload["distanceMeters"] = dist
        } else if let stats = workoutBuilder.statistics(for: HKQuantityType(.distanceWalkingRunning)),
                  let meters = stats.sumQuantity()?.doubleValue(for: .meter()) {
            payload["distanceMeters"] = meters
        }

        if let stats = workoutBuilder.statistics(for: HKQuantityType(.flightsClimbed)),
           let floors = stats.sumQuantity()?.doubleValue(for: .count()) {
            payload["floorsClimbed"] = floors
        }

        // Barometric ascent (gravitational work is derived Dart-side from body mass).
        if _ascentMeters > 0 {
            payload["ascentMeters"] = _ascentMeters
        }

        if !payload.isEmpty {
            heartRateEventSink?(payload)
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Plus gate engine surface (core side)
//
// The round timer reaches the Plus HR-gate engine exclusively through this
// protocol; phases travel as RoundPhase.rawValue strings so the engine stays
// decoupled from the private enum. Plus/GateEngine.swift defines
// makeGateEngine() — the real engine in the private repo, a stub returning
// NoGateEngine in the public export (same filename, so project.pbxproj is
// identical in both repos). With NoGateEngine every enable is false, the gated
// branches above are unreachable, and the round timer behaves byte-for-byte
// like the fixed-time boxing timer.
protocol GateEngineProtocol: AnyObject {
    var warmupEnabled: Bool { get }
    var restEnabled: Bool { get }
    var cooldownEnabled: Bool { get }
    /// Offered any method-channel call the core doesn't handle (e.g. the
    /// module's config push). Returns true when consumed.
    func handle(method: String, arguments: Any?) -> Bool
    /// Reset per-workout state; called when the round timer starts.
    func reset()
    /// Entering a gated phase: reset the engine's clocks; returns the cue to
    /// speak.
    func enterPhase(_ phase: String) -> String
    /// One 1-second tick of a gated phase. Speaks HR cues via `speak`; returns
    /// true when the phase should advance (target reached after the floor, or
    /// the cap hit).
    func tick(phase: String, bpm: Double, speak: (String) -> Void) -> Bool
    /// Cue spoken when a gated phase advances (nil = silent).
    func exitCue(_ phase: String) -> String?
    /// HR-gate fields merged into the 'round' status event during a gated
    /// phase (target / current / elapsed / bounds for the gate panel UI).
    func statusPayload(bpm: Double) -> [String: Any]
}

/// The free core's engine: nothing enabled, nothing handled. The gated code
/// paths in WorkoutManager are unreachable with this engine installed.
final class NoGateEngine: GateEngineProtocol {
    var warmupEnabled: Bool { false }
    var restEnabled: Bool { false }
    var cooldownEnabled: Bool { false }
    func handle(method: String, arguments: Any?) -> Bool { false }
    func reset() {}
    func enterPhase(_ phase: String) -> String { "" }
    func tick(phase: String, bpm: Double, speak: (String) -> Void) -> Bool { true }
    func exitCue(_ phase: String) -> String? { nil }
    func statusPayload(bpm: Double) -> [String: Any] { [:] }
}

// MARK: - Pure, HealthKit-/engine-free logic (unit-tested in RunnerTests)

/// FIFO announcement-queue insertion with BPM-coalescing, pulled out of
/// WorkoutManager so the rule is unit-testable. A new BPM reading replaces a BPM
/// already waiting in the queue (latest reading wins) rather than stacking;
/// everything else appends. Used for both the render queue and the cue queue.
enum AnnounceQueue {
    static func enqueue<T>(_ queue: [T], _ incoming: T, isBpm: (T) -> Bool) -> [T] {
        if isBpm(incoming), let i = queue.firstIndex(where: isBpm) {
            var q = queue
            q[i] = incoming
            return q
        }
        return queue + [incoming]
    }
}
