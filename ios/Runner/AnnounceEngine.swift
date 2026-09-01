import AVFoundation

/// The in-process announce audio pipeline: render → queue → duck → play →
/// un-duck, plus the AVAudioEngine graph and its silent keep-alive loop.
/// Extracted from WorkoutManager, which keeps announce POLICY (BPM cooldowns,
/// boxing-countdown suppression, route-loss gating, zone composition) and
/// feeds this engine plain requests.
///
/// Why this pipeline exists at all (the background-music TTS problem, solved):
/// AVSpeechSynthesizer.speak() renders in an out-of-process daemon whose late
/// mix iOS null-routes when Music owns the AirPods (A2DP) route in sustained
/// background. Rendering to PCM in-process via write(_:toBufferCallback:) and
/// playing through our own AVAudioEngine makes mediaserverd see THIS process
/// producing frames, so it honors our route over Music. A looping silent
/// buffer keeps the tap from being suspended between cues, and Music is
/// ducked by injecting .duckOthers via setCategory on the already-active
/// session — the one lever that works in the background, where setActive(true)
/// is denied. See CLAUDE.md "Background-music TTS over AirPods".
///
/// Main-thread only, like the rest of the announce path.
final class AnnounceEngine {

    // ── Hooks (set by WorkoutManager) ────────────────────────────────────────

    /// Pulls the owner's chosen announce voice at render time — a pull hook
    /// like the other seams, so there is no second copy of the voice to keep
    /// in sync (a forgotten mirror would silently render cues in the default
    /// en-US voice while the picker reports the user's choice).
    var voiceProvider: () -> AVSpeechSynthesisVoice? = { nil }

    /// Which Kokoro voice to speak in. Separate from `voiceProvider` because
    /// the two tiers have disjoint voice namespaces — a system voice
    /// identifier means nothing to Kokoro and vice versa.
    var kokoroVoiceProvider: () -> String = { Corpus.defaultVoice }

    /// Enriches a bare BPM number with zone coaching ("142, zone 4" + an
    /// optional amplified "push"/"ease off" nudge). Composition happens at
    /// RENDER time — a BPM that waited in the queue is composed against the
    /// zones in effect when it finally speaks.
    var composeBpm: ((Double) -> (lead: String, nudge: String?))?

    /// Whether a workout is live — gates the engine-config-change recovery so
    /// an idle app doesn't rebuild the graph on every route change.
    var isActive: () -> Bool = { false }

    /// Called when the underlying AVAudioEngine fails to start: the workout
    /// keeps logging but every cue will be silently guarded out, so the owner
    /// should tell Flutter rather than fail silently.
    var onEngineStartFailed: (() -> Void)?

    // ── Pipeline state ───────────────────────────────────────────────────────

    // TTS synthesizer — used ONLY to RENDER speech to PCM via
    // write(_:toBufferCallback:), never speak() (see the header note).
    private let _synth = AVSpeechSynthesizer()

    // Kokoro renders off the main thread; utility QoS because a cue that is
    // late is still spoken, and this runs during a workout alongside HealthKit.
    private let _kokoroQueue = DispatchQueue(label: "shb.kokoro.render", qos: .userInitiated)

    /// Kokoro, once loaded. READ-ONLY and non-blocking: a nil here means "not
    /// ready", and the caller speaks in the system voice instead of waiting.
    ///
    /// This was a `static let` until 2026-08-28, which was a latent bug with a
    /// 20-second fuse. A lazy static initialises on whatever thread first
    /// touches it — for AnnounceEngine that is `_render`, on the main thread,
    /// mid-workout. And the first load is not cheap: Core ML runs an on-device
    /// Espresso AOT compile to segment the model across ANE and CPU, which
    /// killed the app at launch with 0x8BADF00D ("scene-create watchdog
    /// transgression: exhausted real (wall clock) time allowance of 19.75
    /// seconds") on thread MLE5ProgramLibrary.lazyInitQueue. Precompiling to
    /// .mlmodelc at build time does NOT avoid it — that compile is per-device.
    /// Pre-rendered clips. Cheap to construct (a JSON index; the audio is
    /// loaded lazily per clip), so unlike `kokoro` this one is safe as a lazy
    /// static — there is no Core ML compile behind it.
    static let clips: KokoroClips? = KokoroClips()

    private(set) static var kokoro: KokoroTTS?
    private static var kokoroLoading = false
    private static var kokoroLoadMs: Double?

    /// Load Kokoro off the main thread. Safe to call more than once; safe to
    /// call and ignore. Call it well before the first cue — starting a workout
    /// is the natural moment — never from `application(_:didFinishLaunching…)`.
    @discardableResult
    static func prepareKokoro(_ completion: ((KokoroTTS?) -> Void)? = nil) -> Bool {
        if let ready = kokoro { completion?(ready); return true }
        guard !kokoroLoading else { completion?(nil); return false }
        kokoroLoading = true
        DispatchQueue.global(qos: .utility).async {
            let started = CFAbsoluteTimeGetCurrent()
            let loaded = KokoroTTS()
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            DispatchQueue.main.async {
                kokoro = loaded
                kokoroLoading = false
                kokoroLoadMs = ms
                NSLog("[kokoro] load %@ in %.0f ms", loaded == nil ? "FAILED" : "ok", ms)
                completion?(loaded)
            }
        }
        return false
    }

    /// How long the one-time load took, once it has happened.
    static var kokoroLoadMilliseconds: Double? { kokoroLoadMs }

    private let _engine = AVAudioEngine()
    private let _ttsPlayer = AVAudioPlayerNode()
    private let _keepAlivePlayer = AVAudioPlayerNode()
    // The format the _ttsPlayer→mixer connection currently uses. The
    // synthesizer's render format isn't known until the first cue is rendered
    // (it can vary by voice), so the player is (re)connected to each cue's
    // actual format on demand — scheduleBuffer crashes on a mismatch otherwise.
    private var _ttsConnectedFormat: AVAudioFormat?
    // Guards against overlapping write() renders on the one synthesizer.
    private var _rendering = false
    // Monotonic id for the current playback run. Bumped at each cue start and
    // on every flush; stale completion handlers check it and bail, so a dead
    // cue can't advance the queue or un-duck out from under its successor.
    private var _announceGen = 0
    // Bumped only on a flush. A render that completes after a flush checks
    // this and discards its buffers instead of playing a cue from the old run.
    private var _flushGen = 0
    // FIFO announcement pipeline. Cues are NEVER interrupted: a request that
    // arrives while another is rendering waits in _speakQueue; a rendered cue
    // that arrives while another is playing waits in _cueQueue. The one
    // exception to strict FIFO is BPM coalescing — a new BPM reading REPLACES
    // a BPM cue still waiting in either queue (latest reading wins).
    private struct _SpeakRequest { let text: String; let withBell: Bool; let isBpm: Bool }
    private struct _Cue { let buffers: [AVAudioPCMBuffer]; let isBpm: Bool }
    private var _speakQueue: [_SpeakRequest] = []
    private var _cueQueue: [_Cue] = []
    // True from cue start until its last buffer finishes — the playback-side
    // "busy" flag that routes newly rendered cues into _cueQueue.
    private var _playing = false
    // Fixed format for the silent keep-alive buffer, decoupled from the TTS
    // render format so the engine can start immediately at workout start (the
    // mixer converts the TTS buffers when they arrive).
    private var _keepAliveFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_engineConfigChanged),
            name: .AVAudioEngineConfigurationChange,
            object: _engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // ── Owner-facing surface ─────────────────────────────────────────────────

    /// Whether the audio graph is live (cues can play).
    var isRunning: Bool { _engine.isRunning }

    /// True while anything is rendering, playing, or queued — continuous mode
    /// polls this so announces run back-to-back without piling up.
    var isBusy: Bool { _playing || _rendering || !_speakQueue.isEmpty }

    /// Accepts one announce request. All POLICY (cooldowns, suppression,
    /// route-loss gating) has already been applied by the owner.
    func enqueue(text: String, withBell: Bool, isBpm: Bool) {
        let req = _SpeakRequest(text: text, withBell: withBell, isBpm: isBpm)
        // One render at a time — the synthesizer can't overlap write() calls.
        // A request that lands mid-render queues instead of being dropped; a
        // queued BPM is replaced by the newer reading rather than appended.
        if _rendering {
            _speakQueue = AnnounceQueue.enqueue(_speakQueue, req) { $0.isBpm }
            return
        }
        _renderAndPlay(req)
    }

    // Foreground entry point: set the baseline session, activate it, build +
    // start the engine. Idempotent — also used to re-route when AirPods
    // reconnect.
    func start() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
        try? s.setActive(true, options: [])
        rebuild()
    }

    // Attach + connect the nodes (idempotent), start the engine, and loop the
    // silent keep-alive buffer. Also the recovery path after an interruption
    // or an engine-configuration change.
    func rebuild() {
        let kf = _keepAliveFormat
        if _ttsPlayer.engine == nil { _engine.attach(_ttsPlayer) }
        if _keepAlivePlayer.engine == nil { _engine.attach(_keepAlivePlayer) }
        _engine.connect(_keepAlivePlayer, to: _engine.mainMixerNode, format: kf)
        // The TTS player is reconnected to each cue's real render format in
        // _startCue; connect it now with the last-known (or placeholder)
        // format just so the graph is complete and the engine can start.
        _engine.connect(_ttsPlayer, to: _engine.mainMixerNode, format: _ttsConnectedFormat ?? kf)
        if !_engine.isRunning {
            do { try _engine.start() }
            catch {
                NSLog("SHB audio engine start failed: \(error)")
                onEngineStartFailed?()
                return
            }
        }
        // Restart the silent keep-alive loop deterministically. After an
        // engine configuration change isPlaying can report stale state; a
        // keep-alive that silently fails to resume lets mediaserverd drop the
        // tap and the next cue plays into nothing.
        _keepAlivePlayer.stop()
        if let silence = AVAudioPCMBuffer(pcmFormat: kf, frameCapacity: 4096) {
            silence.frameLength = 4096   // zero-filled = silence
            _keepAlivePlayer.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
            _keepAlivePlayer.play()
        }
    }

    func stop() {
        flush()
        _keepAlivePlayer.stop()
        _engine.stop()
        _rendering = false
    }

    // Flush the whole announcement pipeline: pending renders, queued cues, and
    // the in-flight cue. _rendering is deliberately left alone — a render
    // still in flight clears it on completion, and its result is dropped via
    // the _flushGen check in _playDucked.
    //
    // Always un-ducks: a flush can land mid-cue (interruption, engine config
    // change, route loss), and the cue's own dataPlayedBack un-duck will never
    // fire once the player is stopped — without this, Music stays ducked over
    // silence until the next announce happens to run.
    func flush() {
        _flushGen += 1
        _announceGen += 1
        _speakQueue.removeAll()
        _cueQueue.removeAll()
        _ttsPlayer.stop()
        _playing = false
        _unduck()
    }

    // A route/format change (e.g. AirPods reconnect) tears down the running
    // engine — rebuild it so the next cue has a live graph.
    // AVAudioEngineConfigurationChange is documented to arrive on a background
    // thread; the pipeline is main-owned, so hop before touching it.
    @objc private func _engineConfigChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isActive() else { return }
            // The config change killed any scheduled buffers; clear the
            // pipeline so a half-played cue's bookkeeping can't wedge the queue.
            self.flush()
            self.rebuild()
        }
    }

    // ── Render → play ────────────────────────────────────────────────────────

    // Renders the next queued speak request, if the synthesizer is free.
    private func _drainSpeakQueue() {
        guard !_rendering, !_speakQueue.isEmpty else { return }
        _renderAndPlay(_speakQueue.removeFirst())
    }

    private func _renderAndPlay(_ req: _SpeakRequest) {
        _rendering = true
        let fgen = _flushGen
        // Enrich a bare BPM number with zone coaching ("142, zone 4, push")
        // when the owner supplies a composer. Done here so both the Dart
        // delta-trigger and the native periodic announce (which both pass the
        // plain number) get coached, while the owner's cooldown logic keys off
        // the raw digits.
        let leadText: String
        let nudgeText: String?
        if req.isBpm, let composed = composeBpm?(Double(req.text) ?? 0) {
            leadText = composed.lead
            nudgeText = composed.nudge
        } else {
            leadText = req.text
            nudgeText = nil
        }

        // Render the lead phrase, then (for a steering cue) the nudge as a
        // second, drawn-out, amplified utterance so it lands as a shout rather
        // than a flat word. Both segments queue into one ducked pass.
        let lead = _makeUtterance(leadText, rate: 0.48, pitch: 1.0)
        _render(lead) { [weak self] leadBuffers in
            guard let self = self else { return }
            func finish(_ extra: [AVAudioPCMBuffer]) {
                // Round-transition cue plays as "BELL → (beat) → ROUND 2 /
                // REST" in one protected, ducked pass. The bell is generated
                // at the TTS render format so it queues without a format
                // mismatch. A short gap after the bell lets the metallic ring
                // clear, and the spoken announcement is boosted so it lands
                // clearly after the countdown.
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
            // Slower + lower-pitched bark; "!" sharpens the intonation, and
            // the PCM is soft-clip-boosted so it's clearly louder than the
            // number.
            let utt = self._makeUtterance("\(nudge)!", rate: 0.40, pitch: 0.92)
            self._render(utt) { nudgeBuffers in
                self._amplify(nudgeBuffers, gain: 3.0)
                // A beat of silence so the nudge stands apart from the zone
                // phrase ("below zone 1" … <1s> … "PUSH").
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

    // Build a standard cue utterance in the owner's chosen voice.
    private func _makeUtterance(_ text: String, rate: Float, pitch: Float) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = voiceProvider() ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = rate
        u.volume = 1.0
        u.pitchMultiplier = pitch
        return u
    }

    // Render a cue to PCM. Kokoro (Core ML, CPU + ANE) is the primary voice;
    // AVSpeechSynthesizer.write is the fallback and stays byte-for-byte the
    // path it always was. Both hand back buffers on the main thread, so
    // everything downstream — bell, gap, amplify, duck, play — is unchanged.
    //
    // The utterance is still the unit of work even on the Kokoro path: it
    // already carries the text and the rate the caller chose, and building one
    // costs nothing if Kokoro answers.
    private func _render(_ utt: AVSpeechUtterance, _ done: @escaping ([AVAudioPCMBuffer]) -> Void) {
        // Tier 1: pre-rendered Kokoro. Instant, background-safe, and the same
        // voice as tier 2 because it came off the same weights. Covers the
        // whole closed vocabulary this app actually speaks.
        if let clips = AnnounceEngine.clips,
           let buffers = clips.buffers(for: utt.speechString) {
            DispatchQueue.main.async { done(buffers) }
            return
        }
        // Tier 2: live Kokoro, for anything outside the corpus — only if it has
        // finished its one-time Core ML compile.
        if let tts = AnnounceEngine.kokoro {
            _renderKokoro(tts, utt, done)
            return
        }
        // Not warm yet: speak this cue in the system voice and start the load
        // in the background. Never wait — the first load runs an on-device ANE
        // compile measured in tens of seconds, and a workout cue cannot block
        // on it. Kokoro takes over from the cue after it finishes loading.
        AnnounceEngine.prepareKokoro()
        _renderWithAVSpeech(utt, done)
    }

    /// Kokoro-82M through Core ML, off the main thread.
    ///
    /// A failure here falls back to the system voice rather than dropping the
    /// cue — a workout that says nothing is worse than a workout that says it
    /// in the wrong voice.
    private func _renderKokoro(
        _ tts: KokoroTTS,
        _ utt: AVSpeechUtterance,
        _ done: @escaping ([AVAudioPCMBuffer]) -> Void
    ) {
        let text = utt.speechString
        // AVSpeech rate 0.5 is "normal"; Kokoro speed 1.0 is. The two cue rates
        // in use (0.48 lead, 0.40 nudge) map to 0.96 and 0.80.
        let speed = max(0.5, min(1.5, utt.rate / 0.5))
        let voice = kokoroVoiceProvider()
        _kokoroQueue.async { [weak self] in
            guard let self = self else { return }
            var rendered: AVAudioPCMBuffer?
            do {
                let samples = try tts.synthesize(text: text, voice: voice, speed: speed)
                rendered = Self.makeBuffer(samples: samples,
                                           sampleRate: Double(KokoroTTS.sampleRate))
            } catch {
                NSLog("[kokoro] render failed (%@) — falling back to system voice",
                      error.localizedDescription)
            }
            DispatchQueue.main.async {
                if let buffer = rendered, buffer.frameLength > 0 {
                    done([buffer])
                } else {
                    self._renderWithAVSpeech(utt, done)
                }
            }
        }
    }

    /// [Float] at 24 kHz -> one mono float32 buffer. _playDucked already
    /// reconnects the player to whatever format arrives, so no resampling here.
    private static func makeBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // The original in-process AVSpeech render, unchanged.
    private func _renderWithAVSpeech(_ utt: AVSpeechUtterance, _ done: @escaping ([AVAudioPCMBuffer]) -> Void) {
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

    // Duck Music and play the rendered cue through our engine, un-ducking once
    // the queue drains. Ducking is done by mutating the options on the
    // ALREADY-ACTIVE session (allowed in the background; setActive(true) is
    // not). Cues are queued, never interrupted; only a BPM cue that hasn't
    // started playing yet is replaced by a newer reading.
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
    // match the buffer format or scheduleBuffer crashes — reconnecting
    // requires a stopped player, which is why format changes are handled here,
    // between cues, and never mid-cue.
    private func _startCue(_ cue: _Cue) {
        let fmt = cue.buffers[0].format
        // A cue's segments (lead phrase, silence gap, amplified nudge) come
        // from SEPARATE synthesizer renders, and write() doesn't guarantee the
        // same format across utterances. The player is connected at one format
        // per cue, so convert any stray segment instead of silently dropping
        // it — dropping is how the "push"/"ease off" nudge used to vanish.
        let toPlay = cue.buffers.compactMap { buf in
            buf.format == fmt ? buf : Self._convert(buf, to: fmt)
        }
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

    // ── PCM helpers ──────────────────────────────────────────────────────────

    // Convert one PCM buffer to the target format (sample rate / layout /
    // sample type). Returns nil if the conversion isn't possible (the segment
    // is then dropped — one missing word beats a scheduleBuffer crash).
    private static func _convert(_ buf: AVAudioPCMBuffer, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buf.format, to: fmt) else { return nil }
        let ratio = fmt.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buf.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return nil }
        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buf
        }
        return (convError == nil && out.frameLength > 0) ? out : nil
    }

    // Boost rendered PCM with a tanh soft-clip — louder and grittier (a
    // shout), without the harsh buzz of hard digital clipping. Handles both
    // float32 and int16 render formats; an unsupported sample type just plays
    // unamplified.
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

    // A buffer of pure silence at the given format — used to space cue
    // segments apart (e.g. a beat of silence before the steering nudge).
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

    // Synthesizes a boxing-bell "clang" at the given (TTS render) format so it
    // can be prepended to a transition cue and played through the same engine
    // path. Three struck partials-with-decay in quick succession read as a
    // ring bell. Handles both float32 and int16 render formats — only an
    // unsupported sample type returns nil.
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
        // (hum/prime/tierce/quint/nominal + high inharmonic shimmer)
        // approximate a struck bell. `damp` makes the higher partials decay
        // faster than the fundamental (frequency-dependent damping), so each
        // hit has a bright metallic attack that quickly mellows to the ring —
        // the clang.
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
            // A little overdrive on the bright attack adds metallic grit; the
            // tail (lower amplitude) stays clean.
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
}
