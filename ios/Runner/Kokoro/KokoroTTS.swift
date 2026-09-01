// Written by Halfmarble LLC to replace kokoro-swift's KPipeline, which cannot
// compile without MLX. Follows the dataflow of kokoro-swift by Max Weinbach
// (github.com/mweinbach/kokoro-swift), Apache License 2.0.
//
// Licensed under the Apache License, Version 2.0. See the repository LICENSE,
// and NOTICE for the full attribution. Provenance and every change: VENDOR.md.

import CoreML
import Foundation

/// Kokoro-82M over Core ML, CPU + ANE only.
///
/// Replaces upstream's `KPipeline`, which carries an `InferenceBackend` enum
/// with an MLX case and so cannot compile without MLX. This is the same
/// dataflow with the MLX half removed: G2P -> chunk -> per-chunk style vector
/// -> segmented Core ML forward -> concatenated 24 kHz samples.
///
/// Nothing here touches Metal. That is the requirement, not an incidental
/// property: SteadyHeartBeat speaks while backgrounded, and iOS refuses GPU
/// work from a backgrounded app.
public final class KokoroTTS {
    public static let sampleRate = 24_000

    private let model: SegmentedCoreMLModel
    private let voices: KokoroVoices
    private var g2p: G2P?

    public var availableVoices: [String] { voices.availableVoices() }

    /// Builds from the app bundle. Returns nil when the assets are not bundled,
    /// so the caller can fall back rather than crash — SteadyHeartBeat must
    /// still speak if this tier is missing.
    public convenience init?(bundle: Bundle = .main) {
        guard let resources = bundle.resourceURL,
              let configURL = bundle.url(forResource: "kokoro_config", withExtension: "json") else {
            return nil
        }
        let voicesDir = resources.appendingPathComponent("KokoroVoices", isDirectory: true)
        do {
            try self.init(segmentedDir: resources, configURL: configURL, voicesDir: voicesDir)
        } catch {
            NSLog("[kokoro] unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    public init(segmentedDir: URL, configURL: URL, voicesDir: URL) throws {
        self.model = try SegmentedCoreMLModel(segmentedDir: segmentedDir, configURL: configURL)
        self.voices = KokoroVoices(directory: voicesDir)
    }

    /// Synthesize to raw 24 kHz mono float samples.
    public func synthesize(text: String, voice: String, speed: Float = 1.0) throws -> [Float] {
        let phonemes = try resolveG2P()(text).phonemes
        return try synthesize(phonemes: phonemes, voice: voice, speed: speed)
    }

    public func synthesize(phonemes: String, voice: String, speed: Float = 1.0) throws -> [Float] {
        let normalized = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var audio: [Float] = []
        for chunk in Self.chunkPhonemes(normalized, limit: model.maxPhonemeCount) where !chunk.isEmpty {
            let style = try voices.styleVector(for: voice, phonemeCount: chunk.count)
            let out = try model.forward(phonemes: chunk, refS: style, speed: speed)
            audio.append(contentsOf: out.audio)
        }
        return audio
    }

    /// One throwaway synthesis so the first real cue does not pay Core ML's
    /// model-load and ANE-warmup cost. Call it off the main thread at startup.
    public func warmUp(voice: String) {
        _ = try? synthesize(text: "ready", voice: voice)
    }

    private func resolveG2P() throws -> G2P {
        if let g2p { return g2p }
        let made = try G2P(british: false, unk: "")
        g2p = made
        return made
    }

    /// Split a phoneme string at punctuation/space so no chunk exceeds the
    /// model's fixed context. Copied unchanged from upstream's KPipeline — it
    /// is pure string work with no backend dependency.
    static func chunkPhonemes(_ phonemes: String, limit: Int = 510) -> [String] {
        let trimmed = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed.isEmpty ? [] : [trimmed]
        }

        let breakCharacters = Set([" ", ".", ",", ";", ":", "!", "?", "—", "…"])
        let characters = Array(trimmed)
        var chunks: [String] = []
        var start = 0

        while start < characters.count {
            let endLimit = min(start + limit, characters.count)
            if endLimit == characters.count {
                chunks.append(String(characters[start..<endLimit]).trimmingCharacters(in: .whitespaces))
                break
            }
            var splitIndex = endLimit
            var cursor = endLimit - 1
            while cursor > start + (limit / 2) {
                if breakCharacters.contains(String(characters[cursor])) {
                    splitIndex = cursor + 1
                    break
                }
                cursor -= 1
            }
            chunks.append(String(characters[start..<splitIndex]).trimmingCharacters(in: .whitespaces))
            start = splitIndex
            while start < characters.count,
                  characters[start].unicodeScalars.allSatisfy(\.properties.isWhitespace) {
                start += 1
            }
        }
        return chunks.filter { !$0.isEmpty }
    }
}
