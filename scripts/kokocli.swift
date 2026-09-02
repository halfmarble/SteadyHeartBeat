// kokocli — renders SteadyHeartBeat's spoken vocabulary to the pre-rendered
// clip set the app ships as its voice (`ios/Runner/KokoroAssets/KokoroClips/`).
//
// The app's speech is a CLOSED vocabulary — `Corpus.all()` enumerates it, and
// this tool is the other half of that contract: whatever Corpus lists, this
// renders, so a cue added to WorkoutManager and Corpus but never re-rendered
// shows up as `KokoroClips.unmapped` rather than as a wrong-voiced surprise.
//
//   USAGE
//     kokocli -corpus <outDir> [-voice af_nova] [-assets <dir>]
//     kokocli -say "<text>" <out.m4a> [-voice af_nova] [-speed 1.0] [-assets <dir>]
//
//   BUILD (needs the Core ML assets — see ios/get-kokoro-coreml.sh)
//     A="ios/Runner/KokoroAssets"
//     swiftc -O scripts/kokocli.swift \
//         ios/Runner/Kokoro/{Corpus,KokoroConfig,KokoroTTS,KokoroVoices,SegmentedCoreMLModel}.swift \
//         ios/Runner/Kokoro/Misaki/*.swift -o /tmp/kokocli
//     # Misaki reads its lexicons via Bundle.main, which for a CLI is the
//     # executable's OWN directory — so they must sit beside the binary:
//     for j in us_gold us_silver gb_gold gb_silver; do cat "$A/$j.json" > "/tmp/$j.json"; done
//     /tmp/kokocli -corpus "$A/KokoroClips" -assets "$A"
//
// Rendering is at speed 1.0 deliberately. The app's two cue rates (0.96 lead,
// 0.80 nudge) apply to the LIVE tier only; tier 1 plays the clip as recorded,
// so a clip rendered at anything but 1.0 would make the pre-rendered and live
// tiers sound different for the same words.
//
// Output is silence-trimmed with a 30 ms pad, which is what the shipped corpus
// carries — verified by measuring both: with trimming off, the same synthesis is
// 1.39x longer overall and every clip drifts, while the SPEECH inside matches the
// shipped clips to within 1-3 ms.
//
// A RE-RENDER IS NOT BYTE-IDENTICAL, and that is the model, not this tool.
// Kokoro through Core ML is not run-to-run deterministic: rendering the corpus
// twice here, `num_117` came out 1.951 s and then 1.588 s from the same input —
// the second matching the shipped clip to 21 ms. Across the whole corpus a
// re-render lands within 5 ms on half the clips and within 50 ms on 84% of
// them, with a handful drifting ±0.4 s. So regenerate when the vocabulary
// changes, not to "refresh" clips that are already correct, and expect the diff
// to touch every file.
//
// AAC at 32 kbps mono, not WAV: the whole corpus is 5.2 MB instead of 29 MB,
// and AVAudioFile decodes it with no extra code on the app side.

import AVFoundation
import Foundation

// Top-level statements are only legal in a file called main.swift, and this is
// compiled alongside the app's Kokoro sources — so the entry point is @main.
@main
enum KokoCLI {

    static var args = Array(CommandLine.arguments.dropFirst())

    static let usage = """
    usage:
      kokocli -corpus <outDir> [-voice <name>] [-assets <dir>]
      kokocli -lines <file.txt> <outDir> [-voice <name>] [-speed <x>] [-assets <dir>]
      kokocli -say "<text>" <out.m4a> [-voice <name>] [-speed <x>] [-assets <dir>]
    """

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("kokocli: \(message)\n".utf8))
        exit(2)
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// Pulls `-flag value` out of the argument list, leaving the positionals.
    static func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { fail("\(name) needs a value") }
        let value = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return value
    }

    static func makeEngine(assets: URL) -> KokoroTTS {
        let config = assets.appendingPathComponent("kokoro_config.json")
        guard FileManager.default.fileExists(atPath: config.path) else {
            fail("""
                 no kokoro_config.json under \(assets.path).
                 Run ios/get-kokoro-coreml.sh first — the Core ML weights are 234 MB \
                 and are not in the repo.
                 """)
        }
        // The first load runs Core ML's on-device compile over four segments and
        // is measured in minutes, not seconds. Say so rather than look hung.
        note("kokocli: loading Kokoro (the first run compiles the model — minutes, not seconds)…")
        do {
            return try KokoroTTS(segmentedDir: assets,
                                 configURL: config,
                                 voicesDir: assets.appendingPathComponent("KokoroVoices", isDirectory: true))
        } catch {
            fail("could not load Kokoro: \(error.localizedDescription)")
        }
    }

    /// Trim Kokoro's silence padding, keeping a short pad either side.
    ///
    /// This is NOT cosmetic. Raw Kokoro output carries ~0.25 s of lead-in and
    /// up to ~0.7 s of tail silence; shipped untrimmed, every spoken cue in a
    /// workout gains half a second of dead air, and a "142, zone 4" built from
    /// two clips gains it twice, in the middle of the sentence.
    ///
    /// The threshold is relative to the clip's own peak so a quiet cue is not
    /// trimmed into: 1% of peak catches soft fricative onsets ("Forced…") that
    /// a 2% threshold clips. `padSeconds` is what the shipped corpus carries —
    /// measured at 30–40 ms either side — and matching it keeps a re-render
    /// interchangeable with the clips already in the repo.
    static func trimSilence(_ samples: [Float], padSeconds: Double = 0.030) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else { return samples }
        let threshold = max(peak * 0.01, 1e-4)
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return samples }
        let pad = Int(padSeconds * Double(KokoroTTS.sampleRate))
        let lo = max(0, first - pad)
        let hi = min(samples.count - 1, last + pad)
        return Array(samples[lo...hi])
    }

    /// 24 kHz mono float samples → one AAC-in-m4a file. Returns its duration.
    static func writeClip(_ samples: [Float], to url: URL) throws -> Double {
        guard !samples.isEmpty else {
            throw NSError(domain: "kokocli", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty synthesis"])
        }
        let rate = Double(KokoroTTS.sampleRate)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "kokocli", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not build a PCM buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return Double(samples.count) / rate
    }

    static func renderCorpus(to outDir: String, assets: URL, voice: String) throws {
        let dir = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tts = makeEngine(assets: assets)
        guard tts.availableVoices.contains(voice) else {
            fail("voice '\(voice)' is not in \(assets.path)/KokoroVoices — have: "
                 + tts.availableVoices.sorted().joined(separator: ", "))
        }

        let work = Corpus.all()
        var clips: [String: [String: Any]] = [:]
        let started = Date()

        for (n, item) in work.enumerated() {
            let samples: [Float]
            do {
                samples = trimSilence(try tts.synthesize(text: item.text, voice: voice, speed: 1.0))
            } catch {
                fail("\(item.id) (\"\(item.text)\"): \(error.localizedDescription)")
            }
            do {
                let seconds = try writeClip(samples, to: dir.appendingPathComponent("\(item.id).m4a"))
                clips[item.id] = ["seconds": seconds, "text": item.text]
            } catch {
                fail("\(item.id): \(error.localizedDescription)")
            }
            if (n + 1) % 25 == 0 || n + 1 == work.count {
                note("  \(n + 1)/\(work.count)  \(Int(Date().timeIntervalSince(started)))s")
            }
        }

        // The app cross-checks this "voice" against Corpus.defaultVoice at launch
        // and warns on a mismatch, so it has to name the voice actually rendered.
        let manifest: [String: Any] = [
            "voice": voice,
            "sampleRate": KokoroTTS.sampleRate,
            "count": clips.count,
            "clips": clips,
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: dir.appendingPathComponent("clips.json"))

        guard clips.count == work.count else {
            fail("Corpus lists \(work.count) clips but only \(clips.count) were written")
        }
        let total = clips.values.compactMap { $0["seconds"] as? Double }.reduce(0, +)
        print("kokocli: \(clips.count) clips, \(String(format: "%.1f", total))s of audio, "
              + "voice \(voice) -> \(dir.path)")
    }

    /// Render many lines in ONE process. The model load is the expensive part —
    /// minutes on a cold cache — so -say per line is unusable for a script of a
    /// dozen cues. Input is one `id|text` per line; `#` comments and blank lines
    /// are skipped.
    static func renderLines(from path: String, to outDir: String,
                            assets: URL, voice: String, speed: Float) throws {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        var work: [(id: String, text: String)] = []
        for (n, line) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let bar = t.firstIndex(of: "|") else {
                fail("line \(n + 1): expected `id|text`, got: \(t)")
            }
            let id = String(t[t.startIndex..<bar]).trimmingCharacters(in: .whitespaces)
            let text = String(t[t.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !text.isEmpty else { fail("line \(n + 1): empty id or text") }
            work.append((id, text))
        }
        guard !work.isEmpty else { fail("\(path) has no renderable lines") }

        let dir = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tts = makeEngine(assets: assets)
        guard tts.availableVoices.contains(voice) else {
            fail("voice '\(voice)' is not in \(assets.path)/KokoroVoices")
        }

        var total = 0.0
        for (n, item) in work.enumerated() {
            let samples = trimSilence(try tts.synthesize(text: item.text, voice: voice, speed: speed))
            let seconds = try writeClip(samples, to: dir.appendingPathComponent("\(item.id).m4a"))
            total += seconds
            note(String(format: "  [%2d/%2d] %-22s %5.2fs  %@",
                        n + 1, work.count, (item.id as NSString).utf8String!, seconds,
                        item.text.prefix(48) as NSString))
        }
        print(String(format: "kokocli: %d lines, %.1fs of audio, voice %@ -> %@",
                     work.count, total, voice, dir.path))
    }

    static func main() {
        guard !args.isEmpty else { fail(usage) }

        let voice = option("-voice") ?? Corpus.defaultVoice
        let speedArg = option("-speed")
        let assets = URL(fileURLWithPath: option("-assets") ?? "ios/Runner/KokoroAssets",
                         isDirectory: true)

        do {
            if let outDir = option("-corpus") {
                try renderCorpus(to: outDir, assets: assets, voice: voice)
                return
            }
            // Print the vocabulary as `id|text`, so another renderer can work
            // from Corpus.swift rather than from an existing manifest — a
            // manifest cannot contain a phrase that has just been added.
            if args.contains("-list") {
                for item in Corpus.all() { print("\(item.id)|\(item.text)") }
                return
            }
            if let file = option("-lines") {
                guard let outDir = args.first else { fail(usage) }
                try renderLines(from: file, to: outDir, assets: assets, voice: voice,
                                speed: speedArg.flatMap(Float.init) ?? 1.0)
                return
            }
            if let text = option("-say") {
                guard let outPath = args.first else { fail(usage) }
                let tts = makeEngine(assets: assets)
                let samples = trimSilence(try tts.synthesize(text: text, voice: voice,
                                                            speed: speedArg.flatMap(Float.init) ?? 1.0))
                let seconds = try writeClip(samples, to: URL(fileURLWithPath: outPath))
                print("kokocli: \(String(format: "%.2f", seconds))s -> \(outPath)")
                return
            }
        } catch {
            fail(error.localizedDescription)
        }
        fail(usage)
    }
}
