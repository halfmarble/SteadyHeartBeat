import AVFoundation
import Foundation

/// Pre-rendered Kokoro, the whole vocabulary, shipped as audio.
///
/// SteadyHeartBeat's speech is a CLOSED SET — a heart rate, a zone, a nudge, a
/// round number, and about ten fixed phrases. Rendering it offline buys the
/// Kokoro voice with none of Core ML's costs: no 226 MB of weights, no
/// on-device Espresso AOT compile (measured at ~8 minutes on an M3 and over 40
/// on an iPhone 16 Pro Max), no compute-unit question at all, and nothing that
/// can behave differently in the background — it is PCM, and PCM plays.
///
/// The clips are produced by `scripts/render_corpus_mlx.py`, which renders
/// through KokoroSwift/MLX — NOT through the Core ML path this app runs.
///
/// That is deliberate and it is the reason the app sounds the way it does.
/// Measured 2026-09-01 on identical text: the Core ML port is ~20 dB down in
/// 2-4 kHz against MLX, which is where consonants live, and is heard as muffled
/// and synthetic. MLX needs the GPU, which iOS refuses to a backgrounded app —
/// but the corpus is rendered on a Mac, where that does not apply. So tier 1
/// gets MLX quality and the phone still only plays PCM.
///
/// CONSEQUENCE: tier 1 and tier 2 are NO LONGER the same voice. A cue that
/// falls through to live synthesis sounds worse, not merely later. Keep the
/// corpus complete.
///
/// Anything this cannot map falls through to the caller's existing fallback.
/// `unmapped` records what was asked for and missed — a cue added to
/// WorkoutManager without being added to the corpus shows up there rather than
/// silently becoming a robot voice forever.
final class KokoroClips {
    private let directory: URL
    private let index: [String: Double]        // clip id -> seconds
    private(set) var unmapped: Set<String> = []
    private var cache: [String: AVAudioPCMBuffer] = [:]

    let voice: String

    init?(bundle: Bundle = .main) {
        guard let root = bundle.resourceURL?.appendingPathComponent("KokoroClips", isDirectory: true),
              let data = try? Data(contentsOf: root.appendingPathComponent("clips.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clips = json["clips"] as? [String: [String: Any]] else { return nil }
        directory = root
        voice = (json["voice"] as? String) ?? "unknown"
        var idx: [String: Double] = [:]
        for (id, meta) in clips { idx[id] = (meta["seconds"] as? Double) ?? 0 }
        index = idx
        // The corpus and the app must name the same voice. If they diverge the
        // app asks for clips that were rendered in a different voice's run —
        // or were never rendered at all — so say so at startup rather than
        // discovering it as silence mid-workout.
        if voice != Corpus.defaultVoice {
            NSLog("[kokoroclips] WARNING corpus voice %@ != Corpus.defaultVoice %@",
                  voice, Corpus.defaultVoice)
        }
        NSLog("[kokoroclips] %d clips, voice %@", idx.count, voice)
    }

    var count: Int { index.count }

    /// Map one cue string to the clips that speak it, or nil to fall back.
    ///
    /// The grammar is WorkoutManager._composeBpmAnnounce's, not a guess:
    ///   "142"              bare number, zone coaching off
    ///   "142, zone 4"      number + zone
    ///   "142, zone 4,"     the same, with a nudge to follow
    ///   "push!" / "ease off!" / "Round 2" / a fixed phrase
    func buffers(for text: String) -> [AVAudioPCMBuffer]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }

        if let ids = Self.clipIDs(for: t) {
            var out: [AVAudioPCMBuffer] = []
            for id in ids {
                guard let b = buffer(id) else { unmapped.insert(t); return nil }
                out.append(b)
            }
            return out.isEmpty ? nil : out
        }
        unmapped.insert(t)
        return nil
    }

    /// Deterministic parse of the closed grammar. Returns nil for anything
    /// outside it — a wrong guess here would speak the wrong number, which is
    /// worse than speaking in the wrong voice.
    static func clipIDs(for text: String) -> [String]? {
        // Whole-string matches first: fixed phrases, rounds, nudges.
        for (i, p) in Corpus.fixedPhrases.enumerated() where p == text { return ["fixed_\(i)"] }
        for (i, n) in Corpus.nudges.enumerated() where n == text { return ["nudge_\(i)"] }
        if text.hasPrefix("Round "), let r = Int(text.dropFirst(6)), r >= 1, r <= Corpus.maxRound {
            return ["round_\(r)"]
        }

        // "N" | "N, <zone>" | "N, <zone>,"
        let trailingComma = text.hasSuffix(",")
        let body = trailingComma ? String(text.dropLast()) : text
        let parts = body.components(separatedBy: ", ")
        guard let n = Int(parts[0]), Corpus.bpmRange.contains(n) else { return nil }

        if parts.count == 1 {
            return [trailingComma ? "numc_\(n)" : "num_\(n)"]
        }
        guard parts.count == 2,
              let z = Corpus.zonePhrases.firstIndex(of: parts[1]) else { return nil }
        // The number always carries its comma when a zone follows it.
        return ["numc_\(n)", trailingComma ? "zonec_\(z)" : "zone_\(z)"]
    }

    /// The clip files for a cue, for callers that must PLAY the audio rather
    /// than hand buffers to the announce engine — the AirPods connection prompt
    /// speaks before the engine is running, because producing sound is what
    /// nudges the Bluetooth route into place.
    func fileURLs(for text: String) -> [URL]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ids = Self.clipIDs(for: t) else { unmapped.insert(t); return nil }
        var out: [URL] = []
        for id in ids {
            guard index[id] != nil else { unmapped.insert(t); return nil }
            out.append(directory.appendingPathComponent("\(id).m4a"))
        }
        return out.isEmpty ? nil : out
    }

    private func buffer(_ id: String) -> AVAudioPCMBuffer? {
        if let hit = cache[id] { return hit }
        guard index[id] != nil else { return nil }
        // AAC, not WAV: 29 MB of PCM becomes 5.2 MB at 32 kbps mono, and
        // AVAudioFile decodes it with no extra code.
        let url = directory.appendingPathComponent("\(id).m4a")
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { return nil }
        cache[id] = buf
        return buf
    }
}
