import AVFoundation
import CoreML
import Foundation
import UIKit

/// Proves, on the device, the one property this whole change rests on:
/// **Kokoro renders while SteadyHeartBeat is backgrounded, without the GPU.**
///
/// Launched with `-kokoroprobe`, so it never runs for a real user. It does not
/// need a workout, HealthKit or AirPods — it holds the same silent keep-alive
/// the announce engine holds, synthesizes a cue on a timer, backgrounds itself,
/// and keeps going. A row per attempt lands in Documents/kokoroprobe-*.csv.
///
/// Written because a green build proves the code compiles, not that it speaks.
@MainActor
final class KokoroBackgroundProbe {
    private var handle: FileHandle?
    private var timer: DispatchSourceTimer?
    private var iter = 0
    private var t0 = CFAbsoluteTimeGetCurrent()
    private let engine = AVAudioEngine()
    private let silence = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "shb.kokoroprobe")

    static let shared = KokoroBackgroundProbe()

    func start(foregroundSeconds: Double = 20, totalSeconds: Double = 180) {
        openLog()
        do { try startKeepAlive(); log(note: "keepalive-started", ok: true) }
        catch { log(note: "KEEPALIVE_FAILED \(error.localizedDescription)", ok: false) }

        log(note: "loading Kokoro off the main thread", ok: true)
        AnnounceEngine.prepareKokoro { [weak self] loaded in
            guard let self = self else { return }
            let ms = AnnounceEngine.kokoroLoadMilliseconds ?? 0
            guard let tts = loaded else {
                self.log(note: String(format: "KOKORO_UNAVAILABLE after %.0f ms", ms), ok: false)
                return
            }
            self.log(note: String(format: "LOADED in %.0f ms, voices=%d", ms, tts.availableVoices.count),
                     ok: true)
            self.run(tts, foregroundSeconds: foregroundSeconds, totalSeconds: totalSeconds)
        }
    }

    private func run(_ tts: KokoroTTS, foregroundSeconds: Double, totalSeconds: Double) {
        Task { @MainActor in
            // Ticks FIRST. MLComputePlan.load runs its own compile pass over all
            // four segments and, on the first device run, ate the entire window
            // — so the probe reported a load time and never measured the
            // background synthesis it exists to measure. The plan is a
            // diagnostic; the ticks are the experiment.
            self.startTicking()
            DispatchQueue.main.asyncAfter(deadline: .now() + foregroundSeconds) {
                self.log(note: "SUSPEND_REQUESTED", ok: true)
                UIApplication.shared.perform(Selector(("suspend")))
            }
            // Plan last, and only if asked: it is expensive enough to be its
            // own experiment.
            if ProcessInfo.processInfo.arguments.contains("-plan"),
               #available(iOS 17.4, *), let model = Self.model(of: tts) {
                let plan = await model.computePlanSummary()
                for (seg, summary) in plan.sorted(by: { $0.key < $1.key }) {
                    self.log(note: "COMPUTE_PLAN \(seg): \(summary)", ok: !summary.contains("gpu="))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + totalSeconds) {
                self.log(note: "DONE", ok: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
            }
        }
    }

    private static func model(of tts: KokoroTTS) -> SegmentedCoreMLModel? {
        Mirror(reflecting: tts).children
            .compactMap { $0.value as? SegmentedCoreMLModel }.first
    }

    private func startTicking() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 8.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private nonisolated func tick() {
        guard let tts = AnnounceEngine.kokoro else { return }
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let samples = try tts.synthesize(text: "one hundred forty two", voice: "af_nova")
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            let seconds = Double(samples.count) / Double(KokoroTTS.sampleRate)
            var peak: Float = 0
            for s in samples { peak = max(peak, abs(s)) }
            Task { @MainActor in
                self.iter += 1
                // RTF and peak together: "it returned" and "it returned AUDIO"
                // are different claims, and silence would satisfy the first.
                self.log(note: String(format: "audio=%.2fs rtf=%.2fx peak=%.3f",
                                      seconds, seconds / (ms / 1000), peak),
                         ok: true, latencyMs: ms)
            }
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            Task { @MainActor in
                self.iter += 1
                self.log(note: "FAIL \(error.localizedDescription)", ok: false, latencyMs: ms)
            }
        }
    }

    // ── keep-alive: the same shape AnnounceEngine holds ──────────────────────
    private func startKeepAlive() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
        try s.setActive(true)
        engine.attach(silence)
        let fmt = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(silence, to: engine.mainMixerNode, format: fmt)
        let frames = AVAudioFrameCount(fmt.sampleRate * 0.5)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        for ch in 0..<Int(fmt.channelCount) {
            if let p = buf.floatChannelData?[ch] { for i in 0..<Int(frames) { p[i] = 0 } }
        }
        try engine.start()
        silence.scheduleBuffer(buf, at: nil, options: [.loops])
        silence.play()
    }

    // ── logging ──────────────────────────────────────────────────────────────
    private func openLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = docs.appendingPathComponent("kokoroprobe-\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write("t_s,iter,appstate,thermal,latency_ms,ok,note")
    }

    private func log(note: String, ok: Bool, latencyMs: Double? = nil) {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let lat = latencyMs.map { String(format: "%.1f", $0) } ?? ""
        write(String(format: "%.1f,%d,%@,%@,%@,%d,%@",
                     CFAbsoluteTimeGetCurrent() - t0, iter, state, thermal, lat, ok ? 1 : 0, note))
    }

    private func write(_ line: String) {
        NSLog("[kokoroprobe] %@", line)
        guard let h = handle, let d = (line + "\n").data(using: .utf8) else { return }
        h.write(d)
        try? h.synchronize()
    }
}
