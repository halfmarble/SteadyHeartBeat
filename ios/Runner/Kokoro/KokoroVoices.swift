// Written by Halfmarble LLC to replace kokoro-swift's VoiceLoader and
// CoreMLVoiceAdapter, which read voice packs into an MLXArray. Reads the .npy
// directly instead. Derived in design from kokoro-swift by Max Weinbach
// (github.com/mweinbach/kokoro-swift), Apache License 2.0.
//
// Licensed under the Apache License, Version 2.0. See the repository LICENSE,
// and NOTICE for the full attribution. Provenance and every change: VENDOR.md.

import CoreML
import Foundation

/// Voice packs, without MLX.
///
/// Upstream's `VoiceLoader` returns `MLXArray` and `CoreMLVoiceAdapter` converts
/// it to `MLMultiArray` — which drags MLX (and therefore Metal) into the binary
/// for the sake of reading a .npy file and taking one row out of it. This does
/// the same job with Foundation, so nothing in SteadyHeartBeat's voice path can
/// reach the GPU.
///
/// A Kokoro voice pack is [510, 1, 256] float32: one 256-wide style vector per
/// phoneme-count bucket. `styleVector(for:phonemeCount:)` picks the row.
public final class KokoroVoices {
    private let directory: URL
    private var cache: [String: (rows: Int, width: Int, values: [Float])] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Voice ids present on disk, sorted — this is what a picker should offer.
    public func availableVoices() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".npy") }
            .map { String($0.dropLast(4)) }
            .sorted()
    }

    public func styleVector(for voice: String, phonemeCount: Int) throws -> MLMultiArray {
        let pack = try load(voice)
        let index = max(0, min(phonemeCount - 1, pack.rows - 1))
        let array = try MLMultiArray(
            shape: [NSNumber(value: 1), NSNumber(value: pack.width)],
            dataType: .float32
        )
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: pack.width)
        let start = index * pack.width
        for i in 0..<pack.width { dst[i] = pack.values[start + i] }
        return array
    }

    private func load(_ voice: String) throws -> (rows: Int, width: Int, values: [Float]) {
        if let hit = cache[voice] { return hit }
        let url = directory.appendingPathComponent("\(voice).npy", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KokoroVoiceError.missingVoice(voice)
        }
        let parsed = try Self.readNPY(at: url)
        cache[voice] = parsed
        return parsed
    }

    /// Minimal .npy reader: magic, version, dict header, then raw little-endian
    /// float32. Deliberately strict — it throws on anything it was not built to
    /// read rather than reinterpreting the bytes and producing a voice that is
    /// merely noise.
    static func readNPY(at url: URL) throws -> (rows: Int, width: Int, values: [Float]) {
        let data = try Data(contentsOf: url)
        guard data.count > 12,
              data[0] == 0x93,
              data[1...5] == Data("NUMPY".utf8) else {
            throw KokoroVoiceError.badNPY(url.lastPathComponent, "bad magic")
        }
        let major = data[6]
        let headerLen: Int
        let headerStart: Int
        if major == 1 {
            headerLen = Int(data[8]) | (Int(data[9]) << 8)
            headerStart = 10
        } else {
            headerLen = Int(data[8]) | (Int(data[9]) << 8) | (Int(data[10]) << 16) | (Int(data[11]) << 24)
            headerStart = 12
        }
        guard let header = String(data: data[headerStart..<(headerStart + headerLen)], encoding: .utf8) else {
            throw KokoroVoiceError.badNPY(url.lastPathComponent, "unreadable header")
        }
        guard header.contains("'<f4'") || header.contains("\"<f4\"") else {
            throw KokoroVoiceError.badNPY(url.lastPathComponent, "expected little-endian float32, got \(header)")
        }
        guard header.contains("'fortran_order': False") else {
            throw KokoroVoiceError.badNPY(url.lastPathComponent, "fortran order unsupported")
        }
        // shape: (510, 1, 256) — collapse everything after the first axis into width.
        guard let open = header.range(of: "'shape': ("),
              let close = header.range(of: ")", range: open.upperBound..<header.endIndex) else {
            throw KokoroVoiceError.badNPY(url.lastPathComponent, "no shape")
        }
        let dims = header[open.upperBound..<close.lowerBound]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let rows = dims.first, rows > 0 else {
            throw KokoroVoiceError.badNPY(url.lastPathComponent, "bad shape \(dims)")
        }
        let width = dims.dropFirst().reduce(1, *)
        let body = data[(headerStart + headerLen)...]
        let expected = rows * width * MemoryLayout<Float>.size
        guard body.count >= expected else {
            throw KokoroVoiceError.badNPY(url.lastPathComponent,
                                          "short body: \(body.count) < \(expected)")
        }
        var values = [Float](repeating: 0, count: rows * width)
        _ = values.withUnsafeMutableBytes { dst in
            body.copyBytes(to: dst, count: expected)
        }
        return (rows, width, values)
    }
}

public enum KokoroVoiceError: Error, LocalizedError {
    case missingVoice(String)
    case badNPY(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingVoice(let v):     return "Kokoro voice not bundled: \(v)"
        case .badNPY(let f, let why):  return "Kokoro voice \(f) unreadable: \(why)"
        }
    }
}
