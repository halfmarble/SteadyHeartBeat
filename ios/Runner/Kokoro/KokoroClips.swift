import AVFoundation
import Foundation

/// Pre-rendered Kokoro, the whole vocabulary, shipped as audio.
///
/// SteadyHeartBeat's speech is a CLOSED SET — a heart rate, a zone, a nudge, a
/// round number, and about ten fixed phrases. Rendering it offline buys the
/// Kokoro voice with no model on the phone: no weights, no on-device compile,
/// and nothing that can behave differently in the background — it is PCM, and
/// PCM plays.
///
/// The clips are produced by an offline renderer (not part of this repository)
/// that runs KokoroSwift/MLX on a Mac. MLX needs the GPU, which iOS refuses to a
/// backgrounded app — but the corpus is rendered offline, where that does not
/// apply. An earlier on-device Core ML tier was removed: measured 2026-09-01 on
/// identical text it was ~20 dB down in 2-4 kHz, heard as muffled and synthetic.
///
/// There is no live Kokoro. Anything this cannot map is spoken in the system
/// voice, so keep the corpus complete — CorpusCoverageTests enforces it. A miss
/// logs `[kokoroclips] MISS` with the discriminator, never the text (a cue can
/// be a heart rate).
final class KokoroClips {
    private let directory: URL
    private let index: [String: Double]        // clip id -> seconds
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
                guard let b = buffer(id) else { return nil }
                out.append(b)
            }
            return out.isEmpty ? nil : out
        }
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
        if text.hasPrefix("Climbed ") {
            let words = text.split(separator: " ")
            guard words.count == 3, let n = Int(words[1]) else { return nil }
            if words[2] == "feet", Corpus.climbFeet.contains(n) { return ["climbft_\(n)"] }
            if words[2] == "meters", Corpus.climbMeters.contains(n) { return ["climbm_\(n)"] }
            return nil
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
        // These callers play the file directly, outside AnnounceEngine._render,
        // so this is the only place their miss is recorded.
        guard let ids = Self.clipIDs(for: t) else {
            NSLog("[kokoroclips] MISS file [parsed=0 shipped=0]"); return nil
        }
        var out: [URL] = []
        for id in ids {
            guard index[id] != nil else {
                NSLog("[kokoroclips] MISS file [parsed=1 shipped=0]"); return nil
            }
            out.append(directory.appendingPathComponent("\(id).m4a"))
        }
        return out.isEmpty ? nil : out
    }

    private func buffer(_ id: String) -> AVAudioPCMBuffer? {
        if let hit = cache[id] { return hit }
        guard index[id] != nil else { return nil }
        // Lossless ALAC in .m4a, not WAV: smaller on disk, and AVAudioFile
        // decodes it with no extra code.
        let url = directory.appendingPathComponent("\(id).m4a")
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { return nil }
        cache[id] = buf
        return buf
    }
}
