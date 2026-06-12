import HealthKit
import AVFoundation
import UserNotifications
import CoreMotion

class WorkoutManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {

    static let shared = WorkoutManager()

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    var heartRateEventSink: FlutterEventSink?
    var statusEventSink: FlutterEventSink?

    // TTS synthesizer — used ONLY to RENDER speech to PCM via write(_:toBufferCallback:),
    // never speak(). speak() renders in an out-of-process daemon (speechsynthesisd)
    // whose late mix iOS null-routes when Music owns the AirPods (A2DP) route in
    // sustained background — that's the silence we chased for ten builds. Rendering
    // the audio ourselves and playing it through our own engine (below) makes
    // mediaserverd see THIS process producing frames, so it honors the route.
    private let _synth = AVSpeechSynthesizer()
    private var _speechVoice: AVSpeechSynthesisVoice?

    // In-process audio graph for the announce. _ttsPlayer plays the rendered BPM
    // cue; _keepAlivePlayer loops continuous silence so mediaserverd never suspends
    // our audio tap between announces (an idle tap gets dropped from the hardware
    // mix and the next cue is silenced). The session is HELD active with
    // [.mixWithOthers]; Music is ducked by injecting .duckOthers via setCategory
    // (permitted on an already-active session in the background, where
    // setActive(true) is denied) for the duration of each cue, then stripped.
    private let _engine = AVAudioEngine()
    private let _ttsPlayer = AVAudioPlayerNode()
    private let _keepAlivePlayer = AVAudioPlayerNode()
    // The format the _ttsPlayer→mixer connection currently uses. The synthesizer's
    // render format isn't known until the first cue is rendered (it can vary by
    // voice), so the player is (re)connected to each cue's actual format on demand —
    // scheduleBuffer crashes on a format mismatch otherwise.
    private var _ttsConnectedFormat: AVAudioFormat?
    // Guards against overlapping write() renders on the one synthesizer.
    private var _rendering = false
    // Monotonic id for the current playback run. Bumped at each cue start and on
    // every flush (stop / interruption / engine teardown); stale completion
    // handlers check it and bail, so a dead cue can't advance the queue or
    // un-duck out from under its successor.
    private var _announceGen = 0
    // Bumped only on a flush. A render that completes after a flush checks this
    // and discards its buffers instead of playing a cue from the old run.
    private var _flushGen = 0
    // FIFO announcement pipeline. Cues are NEVER interrupted: a request that
    // arrives while another is rendering waits in _speakQueue; a rendered cue
    // that arrives while another is playing waits in _cueQueue. The one
    // exception to strict FIFO is BPM coalescing — a new BPM reading REPLACES a
    // BPM cue still waiting in either queue (latest reading wins) rather than
    // piling stale readings up behind a long cue.
    private struct _SpeakRequest { let text: String; let withBell: Bool; let isBpm: Bool }
    private struct _Cue { let buffers: [AVAudioPCMBuffer]; let isBpm: Bool }
    private var _speakQueue: [_SpeakRequest] = []
    private var _cueQueue: [_Cue] = []
    // True from cue start until its last buffer finishes — the playback-side
    // "busy" flag that routes newly rendered cues into _cueQueue.
    private var _playing = false
    // Fixed format for the silent keep-alive buffer, decoupled from the TTS render
    // format so the engine can start immediately at workout start (the mixer
    // converts the TTS buffers when they arrive).
    private var _keepAliveFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    }

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

    // MARK: - SHB+ gate engine plug point
    //
    // HR-gated phases (warm-up / recovery-gated rest / cool-down) are driven by
    // the SHB+ module's gate engine, reached only through GateEngineProtocol
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


    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_engineConfigChanged),
            name: .AVAudioEngineConfigurationChange,
            object: _engine
        )
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
        guard session != nil,
              let userInfo = note.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        switch type {
        case .began:
            _flushSpeech()

        case .ended:
            // shouldResume is informational here. When iOS already wants us to
            // resume, one attempt is enough; otherwise (the common post-call
            // case) we retry to ride out call-audio teardown still in flight.
            var shouldResume = false
            if let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    .contains(.shouldResume)
            }
            _reactivateAfterInterruption(retriesRemaining: shouldResume ? 1 : 3)

        @unknown default:
            break
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
            _rebuildEngine()
        } catch {
            NSLog("SHB audio session reactivation failed (retries left \(retriesRemaining)): \(error)")
            guard retriesRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?._reactivateAfterInterruption(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    // Only react to AirPods reconnecting — NOT to app switches (which also
    // fire this notification). Activating the session on every app switch is
    // what kills music playback.
    @objc private func _audioSessionRouteChange(_ note: Notification) {
        guard session != nil,
              let userInfo = note.userInfo,
              let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
              reason == .newDeviceAvailable
        else { return }
        // AirPods reconnected mid-workout — reconfigure and rebuild the engine so
        // the announce graph re-routes to them.
        _startAudioEngine()
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

    // Offers a method-channel call the core doesn't recognize to the SHB+
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

    // MARK: - SHB+ gated-phase seams

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

    // Synthesizes a boxing-bell "clang" at the given (TTS render) format so it can
    // be prepended to a transition cue and played through the same engine path.
    // Three struck partials-with-decay in quick succession read as a ring bell.
    // Handles both float32 and int16 render formats (AVSpeechSynthesizer.write
    // can deliver either) — only an unsupported sample type returns nil.
    private func _makeBell(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let duration = 1.5
        let frames = AVAudioFrameCount(sr * duration)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buf.frameLength = frames

        let twoPi = 2.0 * Double.pi
        let f0 = 660.0
        let decay = 7.5     // base decay rate of the fundamental
        let strikes = [0.0, 0.2, 0.4]   // three hits in quick succession
        // Strongly INHARMONIC partials are what make metal sound metallic — a
        // harmonic series (2×, 3×, 4×) just reads as a pure tone. These ratios
        // (hum/prime/tierce/quint/nominal + high inharmonic shimmer) approximate a
        // struck bell. `damp` makes the higher partials decay faster than the
        // fundamental (frequency-dependent damping), so each hit has a bright
        // metallic attack that quickly mellows to the ring — the clang.
        let partials: [(mult: Double, amp: Double, damp: Double)] = [
            (1.00, 1.00, 1.0),
            (2.00, 0.62, 1.4),
            (2.67, 0.55, 1.8),   // inharmonic
            (3.01, 0.48, 2.0),
            (4.18, 0.40, 2.6),   // inharmonic
            (5.43, 0.30, 3.4),   // inharmonic — high shimmer
            (6.79, 0.22, 4.3),   // inharmonic — high shimmer
            (8.21, 0.14, 5.5),   // inharmonic — bright edge
        ]
        let chCount = Int(format.channelCount)
        let n = Int(frames)

        // Per-frame sample in [-1, 1].
        func sample(_ i: Int) -> Float {
            let t = Double(i) / sr
            var s = 0.0
            for strike in strikes where t >= strike {
                let dt = t - strike
                for p in partials {
                    let env = exp(-decay * p.damp * dt)
                    s += p.amp * env * sin(twoPi * f0 * p.mult * dt)
                }
            }
            // A little overdrive on the bright attack adds metallic grit; the tail
            // (lower amplitude) stays clean.
            return Float(max(-1.0, min(1.0, tanh(s * 0.42))))
        }

        if let chans = buf.floatChannelData {
            for i in 0..<n {
                let v = sample(i)
                for c in 0..<chCount { chans[c][i] = v }
            }
        } else if let chans = buf.int16ChannelData {
            for i in 0..<n {
                let v = Int16((sample(i) * 32767).rounded())
                for c in 0..<chCount { chans[c][i] = v }
            }
        } else {
            return nil
        }
        return buf
    }

    // MARK: - Speech

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
        guard _engine.isRunning else { return }
        let req = _SpeakRequest(text: text, withBell: withBell, isBpm: isBpmAnnounce)
        // One render at a time — the synthesizer can't overlap write() calls. A
        // request that lands mid-render queues instead of being dropped; a queued
        // BPM is replaced by the newer reading rather than appended.
        if _rendering {
            _speakQueue = AnnounceQueue.enqueue(_speakQueue, req) { $0.isBpm }
            return
        }
        _renderAndPlay(req)
    }

    // Renders the next queued speak request, if the synthesizer is free.
    private func _drainSpeakQueue() {
        guard !_rendering, !_speakQueue.isEmpty else { return }
        _renderAndPlay(_speakQueue.removeFirst())
    }

    private func _renderAndPlay(_ req: _SpeakRequest) {
        _rendering = true
        let fgen = _flushGen
        // Enrich a bare BPM number with zone coaching ("142, zone 4, push") when
        // enabled. Done here so both the Dart delta-trigger and the native
        // periodic announce (which both pass the plain number) get coached, while
        // the cooldown logic in speak() keys off the raw digits.
        let leadText: String
        let nudgeText: String?
        if req.isBpm {
            let composed = _composeBpmAnnounce(Double(req.text) ?? 0)
            leadText = composed.lead
            nudgeText = composed.nudge
        } else {
            leadText = req.text
            nudgeText = nil
        }

        // Render the lead phrase, then (for a steering cue) the nudge as a second,
        // drawn-out, amplified utterance so it lands as a shout rather than a flat
        // word. Both segments queue into one ducked pass via _playDucked.
        let lead = _makeUtterance(leadText, rate: 0.48, pitch: 1.0)
        _render(lead) { [weak self] leadBuffers in
            guard let self = self else { return }
            func finish(_ extra: [AVAudioPCMBuffer]) {
                // Round-transition cue plays as "BELL → (beat) → ROUND 2 / REST"
                // in one protected, ducked pass. The bell is generated at the TTS
                // render format so it queues without a format mismatch. A short
                // gap after the bell lets the metallic ring clear, and the spoken
                // announcement is boosted so it lands clearly after the countdown.
                var toPlay = leadBuffers + extra
                if req.withBell, let fmt = toPlay.first?.format,
                   let bell = self._makeBell(format: fmt) {
                    self._amplify(leadBuffers, gain: 1.8)
                    var seq: [AVAudioPCMBuffer] = [bell]
                    if let gap = self._makeSilence(format: fmt, seconds: 0.35) {
                        seq.append(gap)
                    }
                    seq.append(contentsOf: toPlay)
                    toPlay = seq
                }
                self._playDucked(toPlay, isBpm: req.isBpm, flushGen: fgen)
            }
            guard let nudge = nudgeText else { finish([]); return }
            // Slower + lower-pitched bark; "!" sharpens the intonation, and the
            // PCM is soft-clip-boosted so it's clearly louder than the number.
            let utt = self._makeUtterance("\(nudge)!", rate: 0.40, pitch: 0.92)
            self._render(utt) { nudgeBuffers in
                self._amplify(nudgeBuffers, gain: 3.0)
                // A beat of silence so the nudge stands apart from the zone phrase
                // ("below zone 1" … <1s> … "PUSH") rather than running together.
                var seq: [AVAudioPCMBuffer] = []
                if let fmt = leadBuffers.first?.format ?? nudgeBuffers.first?.format,
                   let gap = self._makeSilence(format: fmt, seconds: 1.0) {
                    seq.append(gap)
                }
                seq.append(contentsOf: nudgeBuffers)
                finish(seq)
            }
        }
    }

    // Build a standard cue utterance in the user's chosen voice.
    private func _makeUtterance(_ text: String, rate: Float, pitch: Float) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = _speechVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = rate
        u.volume = 1.0
        u.pitchMultiplier = pitch
        return u
    }

    // Render an utterance to PCM in-process; calls done (on main) with the
    // buffers. The callback receives successive buffers, then one with
    // frameLength 0 to signal completion. Render serially — one write at a time.
    private func _render(_ utt: AVSpeechUtterance, _ done: @escaping ([AVAudioPCMBuffer]) -> Void) {
        var buffers: [AVAudioPCMBuffer] = []
        var finished = false
        _synth.write(utt) { buf in
            guard let pcm = buf as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                buffers.append(pcm)
            } else if !finished {
                finished = true
                let collected = buffers
                DispatchQueue.main.async { done(collected) }
            }
        }
    }

    // Boost rendered PCM with a tanh soft-clip — louder and grittier (a shout),
    // without the harsh buzz of hard digital clipping. Handles both float32 and
    // int16 render formats; an unsupported sample type just plays unamplified.
    private func _amplify(_ buffers: [AVAudioPCMBuffer], gain: Float) {
        for buf in buffers {
            let frames = Int(buf.frameLength)
            let channels = Int(buf.format.channelCount)
            if let chans = buf.floatChannelData {
                for ch in 0..<channels {
                    let p = chans[ch]
                    for i in 0..<frames { p[i] = tanhf(p[i] * gain) }
                }
            } else if let chans = buf.int16ChannelData {
                for ch in 0..<channels {
                    let p = chans[ch]
                    for i in 0..<frames {
                        let f = Float(p[i]) / 32768.0
                        p[i] = Int16((tanhf(f * gain) * 32767).rounded())
                    }
                }
            }
        }
    }

    // A buffer of pure silence at the given format — used to space cue segments
    // apart (e.g. a beat of silence before the steering nudge). Format-agnostic.
    private func _makeSilence(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buf.frameLength = frames
        let n = Int(frames)
        let chCount = Int(format.channelCount)
        // AVAudioPCMBuffer isn't guaranteed zero-initialized — clear it explicitly.
        if let chans = buf.floatChannelData {
            for c in 0..<chCount { for i in 0..<n { chans[c][i] = 0 } }
        } else if let chans = buf.int16ChannelData {
            for c in 0..<chCount { for i in 0..<n { chans[c][i] = 0 } }
        }
        return buf
    }

    // Duck Music and play the rendered cue through our engine, un-ducking once
    // the queue drains. Ducking is done by mutating the options on the
    // ALREADY-ACTIVE session (allowed in the background; setActive(true) is not).
    // Cues are queued, never interrupted; only a BPM cue that hasn't started
    // playing yet is replaced by a newer reading.
    private func _playDucked(_ buffers: [AVAudioPCMBuffer], isBpm: Bool, flushGen: Int) {
        _rendering = false
        // Kick the next queued render (if any) so it's ready when this cue ends.
        defer { _drainSpeakQueue() }
        // A flush (stop / interruption / engine teardown) happened mid-render —
        // this cue belongs to the old run, drop it.
        guard flushGen == _flushGen else { return }
        guard _engine.isRunning, !buffers.isEmpty else { return }
        if _playing {
            _cueQueue = AnnounceQueue.enqueue(_cueQueue, _Cue(buffers: buffers, isBpm: isBpm)) { $0.isBpm }
            return
        }
        _startCue(_Cue(buffers: buffers, isBpm: isBpm))
    }

    // Schedule one cue on the (idle) player. The player↔mixer connection must
    // match the buffer format or scheduleBuffer crashes — reconnecting requires
    // a stopped player, which is why format changes are handled here, between
    // cues, and never mid-cue.
    private func _startCue(_ cue: _Cue) {
        let fmt = cue.buffers[0].format
        let toPlay = cue.buffers.filter { $0.format == fmt }
        guard !toPlay.isEmpty else { _cueFinished(); return }
        _playing = true
        _announceGen += 1
        let gen = _announceGen
        if _ttsConnectedFormat == nil || _ttsConnectedFormat != fmt {
            _ttsPlayer.stop()
            _engine.connect(_ttsPlayer, to: _engine.mainMixerNode, format: fmt)
            _ttsConnectedFormat = fmt
        }
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
        let lastIdx = toPlay.count - 1
        for (i, buf) in toPlay.enumerated() {
            let isLast = (i == lastIdx)
            _ttsPlayer.scheduleBuffer(buf, at: nil, options: [],
                                      completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard isLast else { return }
                DispatchQueue.main.async {
                    // Ignore the completion of a flushed (stopped) run.
                    guard let self = self, self._announceGen == gen else { return }
                    self._cueFinished()
                }
            }
        }
        if !_ttsPlayer.isPlaying { _ttsPlayer.play() }
    }

    // The current cue finished cleanly: start the next queued cue (staying
    // ducked between them), or go idle and restore Music's volume.
    private func _cueFinished() {
        if !_cueQueue.isEmpty {
            _startCue(_cueQueue.removeFirst())
        } else {
            _playing = false
            _unduck()
        }
    }

    private func _unduck() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.mixWithOthers])
    }

    // Flush the whole announcement pipeline: pending renders, queued cues, and
    // the in-flight cue. _rendering is deliberately left alone — a render still
    // in flight clears it on completion, and its result is dropped via the
    // _flushGen check in _playDucked.
    private func _flushSpeech() {
        _flushGen += 1
        _announceGen += 1
        _speakQueue.removeAll()
        _cueQueue.removeAll()
        _ttsPlayer.stop()
        _playing = false
    }

    func stopSpeaking() {
        _flushSpeech()
        _unduck()
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
        if _continuousAnnounce && (_playing || _rendering || !_speakQueue.isEmpty) { return }
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
        _startAudioEngine()
        // Immediate confirmation that monitoring is live — also warms up the engine
        // so the first BPM cue plays without first-render latency. Synthesized live
        // in the user's chosen voice (no pre-recorded clips).
        speak(text: "Monitoring heart rate")

        _latestBpm = 0
        _lastHrSampleAt = 0
        _lastBpmAnnouncedAt = 0
        _startAltimeter()
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
        builder?.beginCollection(withStart: startDate) { success, error in
            DispatchQueue.main.async { completion(success, error?.localizedDescription) }
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
        _stopAnnounceTimer()
        _stopRoundTimer()
        _stopAudioEngine()
        _stopAltimeter()
        _latestBpm = 0
        _lastHrSampleAt = 0
        _lastBpmAnnouncedAt = 0
        session?.end()
        builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            guard let self = self else { return }
            let finalize: () -> Void = { [weak self] in
                DispatchQueue.main.async {
                    self?.builder = nil
                    self?.session = nil
                    try? AVAudioSession.sharedInstance().setActive(
                        false, options: .notifyOthersOnDeactivation
                    )
                }
            }
            if self._saveToHealth {
                self.builder?.finishWorkout { _, _ in finalize() }
            } else {
                // Discard so nothing is written to HealthKit (and nothing syncs
                // out via iCloud Health). Any heart-rate samples the system
                // collects from the AirPods are separate and outside our control.
                self.builder?.discardWorkout()
                finalize()
            }
        }
    }

    // MARK: - In-process audio engine
    //
    // The announce is rendered to PCM (see speak/_playDucked) and played through
    // this engine instead of AVSpeechSynthesizer.speak(), so mediaserverd sees
    // THIS process producing frames and honors our route over Music on AirPods in
    // the background. A looping silent buffer keeps the tap from being suspended
    // between cues.

    // Foreground entry point: set the baseline session, activate it, build + start
    // the engine. Idempotent — also used to re-route when AirPods reconnect.
    private func _startAudioEngine() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
        try? s.setActive(true, options: [])
        _rebuildEngine()
    }

    // Attach + connect the nodes (idempotent), start the engine, and loop the
    // silent keep-alive buffer. Also the recovery path after an interruption or an
    // engine-configuration change.
    private func _rebuildEngine() {
        let kf = _keepAliveFormat
        if _ttsPlayer.engine == nil { _engine.attach(_ttsPlayer) }
        if _keepAlivePlayer.engine == nil { _engine.attach(_keepAlivePlayer) }
        _engine.connect(_keepAlivePlayer, to: _engine.mainMixerNode, format: kf)
        // The TTS player is reconnected to each cue's real render format in
        // _playDucked; connect it now with the last-known (or placeholder) format
        // just so the graph is complete and the engine can start.
        _engine.connect(_ttsPlayer, to: _engine.mainMixerNode, format: _ttsConnectedFormat ?? kf)
        if !_engine.isRunning {
            do { try _engine.start() }
            catch { return }
        }
        if !_keepAlivePlayer.isPlaying,
           let silence = AVAudioPCMBuffer(pcmFormat: kf, frameCapacity: 4096) {
            silence.frameLength = 4096   // zero-filled = silence
            _keepAlivePlayer.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
            _keepAlivePlayer.play()
        }
    }

    private func _stopAudioEngine() {
        _flushSpeech()
        _keepAlivePlayer.stop()
        _engine.stop()
        _rendering = false
    }

    // A route/format change (e.g. AirPods reconnect) tears down the running engine
    // — rebuild it so the next cue has a live graph.
    @objc private func _engineConfigChanged() {
        guard session != nil else { return }
        // The config change killed any scheduled buffers; clear the pipeline so
        // a half-played cue's bookkeeping can't wedge the queue.
        _flushSpeech()
        _rebuildEngine()
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
    // onset → out of bed, awake periods included) and take the MEDIAN SDNN
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
        let type = HKCategoryType(.sleepAnalysis)
        let end = Date()
        let start = end.addingTimeInterval(-15 * 24 * 3600)
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
            // Stamp each night's sleep-midpoint as local seconds-since-midnight —
            // the one piece OvernightMath can't do (it needs the calendar/timezone).
            let cal = Calendar.current
            let scored: [OvernightMath.ScoredNight] = OvernightMath.clusters(segs).compactMap { cluster in
                guard let night = OvernightMath.night(from: cluster) else { return nil }
                let midEpoch = (night.sleepOnset.timeIntervalSince1970 + night.bedEnd.timeIntervalSince1970) / 2
                let mid = Date(timeIntervalSince1970: midEpoch)
                let tod = mid.timeIntervalSince(cal.startOfDay(for: mid))
                return OvernightMath.ScoredNight(night: night, midpointTOD: tod)
            }
            completion(OvernightMath.selectNight(scored))
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
    // whole in-bed span (sleep onset → out of bed, awake periods included) —
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

    // MARK: - AirPods detection via audio route

    func checkAirPodsInfo() -> [String: Any] {
        try? AVAudioSession.sharedInstance().setActive(true)
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
            case .ended:    self.statusEventSink?(["type": "state", "value": "stopped"])
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

        if let stats = workoutBuilder.statistics(for: HKQuantityType(.stepCount)),
           let steps = stats.sumQuantity()?.doubleValue(for: .count()) {
            payload["steps"] = steps
        }

        if let stats = workoutBuilder.statistics(for: HKQuantityType(.distanceWalkingRunning)),
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
            DispatchQueue.main.async { self.heartRateEventSink?(payload) }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - SHB+ gate engine surface (core side)
//
// The round timer reaches the SHB+ HR-gate engine exclusively through this
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
    struct Night: Equatable {
        let sleepOnset: Date     // first asleep start (a Night always has sleep)
        let bedEnd: Date         // last segment end — out of bed
        let asleepSeconds: Double // total asleep time (overlaps merged)
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
    /// last segment end, asleepSeconds = union duration of the asleep segments
    /// (overlaps merged, so two sleep-tracking sources can't double-count). Nil
    /// when the cluster has no asleep segment (e.g. only inBed recorded).
    static func night(from cluster: [Segment]) -> Night? {
        let asleep = cluster.filter { $0.isAsleep }
        guard let onset = asleep.map({ $0.start }).min() else { return nil }
        return Night(
            sleepOnset: onset,
            bedEnd: cluster.map { $0.end }.max() ?? onset,
            asleepSeconds: unionDuration(asleep.map { (start: $0.start, end: $0.end) }))
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

    /// Picks the night for bed HRV / bed HR: the most recent (latest out-of-bed)
    /// night with ≥ `minAsleep` of sleep whose sleep midpoint is within
    /// `toleranceTOD` of the user's normal sleep midpoint. Normal midpoint is the
    /// circular mean of the qualifying nights' midpoints once there are at least
    /// `minHistoryNights`; before that, a default overnight band centered on
    /// `defaultMidpointTOD`. Nil when nothing qualifies (caller then falls back
    /// to the most recent single sample).
    static func selectNight(
        _ scored: [ScoredNight],
        minAsleep: TimeInterval = 3 * 3600,
        toleranceTOD: Double = 4 * 3600,
        defaultMidpointTOD: Double = 3 * 3600,   // 03:00 — typical mid-sleep
        minHistoryNights: Int = 3
    ) -> Night? {
        let qualifying = scored.filter { $0.night.asleepSeconds >= minAsleep }
        guard !qualifying.isEmpty else { return nil }
        let normalMidpoint = qualifying.count >= minHistoryNights
            ? (circularMeanTOD(qualifying.map { $0.midpointTOD }) ?? defaultMidpointTOD)
            : defaultMidpointTOD
        return qualifying
            .filter { circularDistanceTOD($0.midpointTOD, normalMidpoint) <= toleranceTOD }
            .max { $0.night.bedEnd < $1.night.bedEnd }?
            .night
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
