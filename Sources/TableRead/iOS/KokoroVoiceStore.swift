#if os(iOS)
import Foundation

// MARK: - Kokoro voice embedding store

/// Loads Kokoro voice style matrices from per-voice binary files.
///
/// Each `.kokoro` file is produced by `scripts/convert_kokoro_voices.py` and
/// contains raw float32 data for a single voice: 510 rows × 256 columns, stored
/// row-major, matching the npz shape (510, 1, 256) squeezed on axis 1.
///
/// File layout:
///   Bytes 0–3:   ASCII magic "KOKR"
///   Byte  4:     Format version (0x01)
///   Bytes 5–6:   uint16 LE — row count (510)
///   Bytes 7–8:   uint16 LE — column count (256)
///   Bytes 9…:    float32 LE values, row-major
actor KokoroVoiceStore {
    static let storageDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TableRead/kokoro-voices", isDirectory: true)
    }()

    private var cache: [String: [[Float]]] = [:]

    // MARK: - Public API

    /// Returns the style matrix for `voiceID`, loading from disk if needed.
    /// Shape: [rows][cols] = [510][256].
    func styleMatrix(for voiceID: String) throws -> [[Float]] {
        if let cached = cache[voiceID] { return cached }
        let matrix = try loadFromDisk(voiceID: voiceID)
        cache[voiceID] = matrix
        return matrix
    }

    /// The style vector to use for a given token sequence length.
    /// Kokoro picks the row index = tokenCount (clamped to rows - 1).
    func styleVector(for voiceID: String, tokenCount: Int) throws -> [Float] {
        let matrix = try styleMatrix(for: voiceID)
        let idx = min(tokenCount, matrix.count - 1)
        return matrix[idx]
    }

    /// Returns true if the voice file exists on disk.
    func isDownloaded(voiceID: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: voiceID).path)
    }

    /// Lists all voice IDs available on disk.
    func downloadedVoiceIDs() -> [String] {
        let dir = KokoroVoiceStore.storageDir
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items
            .filter { $0.hasSuffix(".kokoro") }
            .map { String($0.dropLast(".kokoro".count)) }
    }

    // MARK: - Disk loading

    private func fileURL(for voiceID: String) -> URL {
        KokoroVoiceStore.storageDir.appendingPathComponent("\(voiceID).kokoro")
    }

    private func loadFromDisk(voiceID: String) throws -> [[Float]] {
        let url = fileURL(for: voiceID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IOSTTSError.downloadRequired("Kokoro voice '\(voiceID)'")
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // Validate magic + version
        guard data.count >= 9 else { throw KokoroVoiceError.invalidFile("Too short") }
        let magic = String(bytes: data[0..<4], encoding: .ascii)
        guard magic == "KOKR" else { throw KokoroVoiceError.invalidFile("Bad magic: \(magic ?? "?")") }
        guard data[4] == 0x01 else { throw KokoroVoiceError.invalidFile("Unsupported version \(data[4])") }

        let rows = Int(data[5]) | (Int(data[6]) << 8)
        let cols = Int(data[7]) | (Int(data[8]) << 8)
        let expectedBytes = 9 + rows * cols * MemoryLayout<Float>.size
        guard data.count == expectedBytes else {
            throw KokoroVoiceError.invalidFile(
                "Expected \(expectedBytes) bytes, got \(data.count)"
            )
        }

        // Read flat float32 array and reshape to [rows][cols]
        let floatCount = rows * cols
        var flat = [Float](repeating: 0, count: floatCount)
        data.withUnsafeBytes { ptr in
            let src = ptr.baseAddress!.advanced(by: 9).assumingMemoryBound(to: Float.self)
            flat.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.initialize(from: src, count: floatCount)
            }
        }

        var matrix = [[Float]]()
        matrix.reserveCapacity(rows)
        for r in 0..<rows {
            let start = r * cols
            matrix.append(Array(flat[start..<start + cols]))
        }
        return matrix
    }
}

enum KokoroVoiceError: LocalizedError {
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let reason): "Invalid Kokoro voice file: \(reason)"
        }
    }
}
#endif
