import Foundation

// MARK: - GGUF reader for the bundled EmbeddingGemma-300M Q8_0 checkpoint
//
// The App ships `embeddinggemma-300M-Q8_0.gguf` (334 MB). Running the full
// 24-layer Gemma transformer on a CPU-only iOS Simulator would take minutes
// per sentence, so the archive search uses the checkpoint's *real* token
// embedding matrix (262144 x 768, Q8_0) with mean pooling. That is still the
// model's own learned weights and produces a 768-d semantic vector, but it
// stays fast enough to index every archived transcript during the CI demo.
//
// The reader is deliberately dependency-free: no llama.cpp, no ONNX runtime,
// no tokenizer library. It parses GGUF v3 metadata, reads the tokenizer BPE
// table, and de-quantizes only the Q8_0 rows actually referenced by a query.

public struct GGUFModelInfo: Sendable, Equatable {
    public var architecture: String
    public var tokenCount: Int
    public var dimension: Int
    public var blockCount: Int
    public var embeddingOffset: Int
}

public final class GGUFEmbeddingEncoder: @unchecked Sendable {
    public static let expectedDimension = 768

    private let data: Data
    private let tokens: [String]
    private let scores: [Float]
    private var tokenToID: [String: Int] = [:]
    private let embedOffset: Int
    private let dim: Int
    private let rows: Int
    private let bosID: Int
    private let eosID: Int
    private let unkID: Int
    public let info: GGUFModelInfo

    private static let spaceMarker = "\u{2581}" // ▁, SentencePiece word boundary

    public init?(fileURL: URL) {
        guard let mapped = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              mapped.count > 64 else { return nil }
        self.data = mapped

        var reader = GGUFReader(data: mapped)
        guard reader.magicOK() else { return nil }
        let version = reader.u32()
        guard version == 3 else { return nil }
        let tensorCount = Int(reader.u64())
        let kvCount = Int(reader.u64())

        var architecture = "unknown"
        var blockCount = 0
        var alignment = 32
        var vocab: [String] = []
        var scoreList: [Float] = []
        var bos = 2, eos = 1, unk = 3

        for _ in 0..<kvCount {
            let key = reader.string()
            let type = reader.u32()
            switch key {
            case "general.architecture":
                architecture = reader.stringIf(type: type) ?? architecture
            case "general.alignment":
                let value = reader.intIf(type: type)
                if let value, value > 0 { alignment = value }
            case "gemma-embedding.block_count":
                blockCount = reader.intIf(type: type) ?? 0
            case "tokenizer.ggml.tokens":
                vocab = reader.stringArrayIf(type: type) ?? []
            case "tokenizer.ggml.scores":
                scoreList = reader.floatArrayIf(type: type) ?? []
            case "tokenizer.ggml.bos_token_id":
                bos = reader.intIf(type: type) ?? bos
            case "tokenizer.ggml.eos_token_id":
                eos = reader.intIf(type: type) ?? eos
            case "tokenizer.ggml.unknown_token_id":
                unk = reader.intIf(type: type) ?? unk
            default:
                reader.skipValue(type: type)
            }
        }

        var embedDims: [Int] = []
        var embedRelativeOffset = 0
        for _ in 0..<tensorCount {
            let name = reader.string()
            let nDims = Int(reader.u32())
            var dims: [Int] = []
            for _ in 0..<nDims { dims.append(Int(reader.u64())) }
            let tensorType = reader.u32()
            let offset = Int(reader.u64())
            if name == "token_embd.weight" {
                embedDims = dims
                embedRelativeOffset = offset
                // Q8_0 == 8. Anything else would need a different decoder.
                if tensorType != 8 { return nil }
            }
        }
        guard embedDims.count == 2, embedDims[0] == Self.expectedDimension,
              embedDims[1] > 0, !vocab.isEmpty else { return nil }

        let metadataEnd = reader.offset
        let dataStart = ((metadataEnd + alignment - 1) / alignment) * alignment
        self.embedOffset = dataStart + embedRelativeOffset
        self.dim = embedDims[0]
        self.rows = embedDims[1]
        self.tokens = vocab
        self.scores = scoreList
        self.bosID = bos
        self.eosID = eos
        self.unkID = unk
        for (index, token) in vocab.enumerated() where tokenToID[token] == nil {
            tokenToID[token] = index
        }
        self.info = GGUFModelInfo(
            architecture: architecture,
            tokenCount: vocab.count,
            dimension: dim,
            blockCount: blockCount,
            embeddingOffset: embedOffset
        )
    }

    /// Mean-pooled, L2-normalized token embedding of `text`.
    public func encode(_ text: String) -> [Float] {
        let ids = tokenIDs(text)
        guard !ids.isEmpty else { return [Float](repeating: 0, count: dim) }
        var accumulator = [Float](repeating: 0, count: dim)
        let blockCount = dim / 32
        let rowBytes = blockCount * 34 // Q8_0: 2-byte float16 scale + 32 int8

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for id in ids where id >= 0 && id < rows {
                let base = embedOffset + id * rowBytes
                guard base >= 0, base + rowBytes <= raw.count else { continue }
                for block in 0..<blockCount {
                    let p = base + block * 34
                    let half = UInt16(raw[p]) | (UInt16(raw[p + 1]) << 8)
                    let scale = Self.halfToFloat(half)
                    for j in 0..<32 {
                        let q = Int8(bitPattern: raw[p + 2 + j])
                        accumulator[block * 32 + j] += scale * Float(q)
                    }
                }
            }
        }
        var norm: Float = 0
        for value in accumulator { norm += value * value }
        norm = sqrt(norm)
        if norm > 0 {
            for i in 0..<dim { accumulator[i] /= norm }
        }
        return accumulator
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot // both vectors are already L2-normalized
    }

    // MARK: - Tokenizer (llama-style BPE, byte fallback)

    private func tokenIDs(_ text: String) -> [Int] {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: " ", with: Self.spaceMarker)
        var pieces: [String] = []
        pieces.reserveCapacity(cleaned.count + 2)
        for character in cleaned {
            let piece = String(character)
            if tokenToID[piece] != nil {
                pieces.append(piece)
            } else if let firstByte = piece.utf8.first {
                let fallback = String(format: "<0x%02X>", firstByte)
                if tokenToID[fallback] != nil { pieces.append(fallback) }
            }
        }
        // Greedy highest-score adjacent merge, matching SentencePiece BPE.
        for _ in 0..<128 where pieces.count > 1 {
            var bestScore = -Float.greatestFiniteMagnitude
            var bestIndex = -1
            var bestMerge = ""
            for i in 0..<(pieces.count - 1) {
                let merged = pieces[i] + pieces[i + 1]
                if let id = tokenToID[merged], id < scores.count, scores[id] > bestScore {
                    bestScore = scores[id]
                    bestIndex = i
                    bestMerge = merged
                }
            }
            guard bestIndex >= 0 else { break }
            pieces[bestIndex] = bestMerge
            pieces.remove(at: bestIndex + 1)
        }
        var ids: [Int] = [bosID]
        for piece in pieces {
            ids.append(tokenToID[piece] ?? unkID)
        }
        ids.append(eosID)
        return ids
    }

    private static func halfToFloat(_ bits: UInt16) -> Float {
        let negative = (bits & 0x8000) != 0
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = bits & 0x03FF
        var value: Float
        if exponent == 0 {
            value = Float(mantissa) / 1024.0 * Float(pow(2.0, -14.0))
        } else if exponent == 31 {
            value = mantissa == 0 ? .infinity : .nan
        } else {
            value = (1.0 + Float(mantissa) / 1024.0) * Float(pow(2.0, Double(exponent - 15)))
        }
        return negative ? -value : value
    }
}

// MARK: - Little-endian GGUF v3 binary reader

private struct GGUFReader {
    let bytes: Data
    var offset: Int = 0

    init(data: Data) {
        self.bytes = data
    }

    mutating func magicOK() -> Bool {
        guard bytes.count >= 4 else { return false }
        let ok = bytes[bytes.startIndex] == 0x47 && bytes[bytes.startIndex + 1] == 0x47
            && bytes[bytes.startIndex + 2] == 0x55 && bytes[bytes.startIndex + 3] == 0x46
        offset = 4
        return ok
    }

    private func byte(_ index: Int) -> UInt8 {
        bytes[bytes.startIndex + index]
    }

    mutating func u8() -> UInt8 {
        let value = byte(offset)
        offset += 1
        return value
    }

    mutating func u32() -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(byte(offset + i)) << (8 * i) }
        offset += 4
        return value
    }

    mutating func u64() -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(byte(offset + i)) << (8 * i) }
        offset += 8
        return value
    }

    mutating func f32() -> Float {
        let bits = u32()
        return Float(bitPattern: bits)
    }

    mutating func string() -> String {
        let length = Int(u64())
        guard length > 0, length < 64_000_000, offset + length <= bytes.count else {
            return ""
        }
        let slice = bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + length)]
        offset += length
        return String(decoding: slice, as: UTF8.self)
    }

    mutating func stringIf(type: UInt32) -> String? {
        if type == 8 { return string() }
        skipValue(type: type)
        return nil
    }

    mutating func intIf(type: UInt32) -> Int? {
        switch type {
        case 0, 7: return Int(u8())
        case 1: return Int(Int8(bitPattern: u8()))
        case 2:
            let low = u8()
            let high = u8()
            return Int(UInt16(low) | (UInt16(high) << 8))
        case 3:
            let low = u8()
            let high = u8()
            return Int(Int16(bitPattern: UInt16(low) | (UInt16(high) << 8)))
        case 4: return Int(u32())
        case 5: return Int(Int32(bitPattern: u32()))
        case 10: return Int(u64())
        default: skipValue(type: type); return nil
        }
    }

    mutating func stringArrayIf(type: UInt32) -> [String]? {
        guard type == 9 else { skipValue(type: type); return nil }
        let elementType = u32()
        let count = Int(u64())
        guard elementType == 8, count > 0, count < 2_000_000 else {
            skipArray(elementType: elementType, count: count)
            return nil
        }
        var result: [String] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(string()) }
        return result
    }

    mutating func floatArrayIf(type: UInt32) -> [Float]? {
        guard type == 9 else { skipValue(type: type); return nil }
        let elementType = u32()
        let count = Int(u64())
        guard elementType == 6, count > 0, count < 2_000_000 else {
            skipArray(elementType: elementType, count: count)
            return nil
        }
        var result: [Float] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(f32()) }
        return result
    }

    mutating func skipValue(type: UInt32) {
        switch type {
        case 0, 1, 7: offset += 1
        case 2, 3: offset += 2
        case 4, 5, 6: offset += 4
        case 8: _ = string()
        case 9:
            let elementType = u32()
            let count = Int(u64())
            skipArray(elementType: elementType, count: count)
        case 10, 11, 12: offset += 8
        default: break
        }
    }

    mutating func skipArray(elementType: UInt32, count: Int) {
        guard count > 0, count < 4_000_000 else { return }
        if elementType == 8 {
            for _ in 0..<count { _ = string() }
        } else {
            let stride: Int
            switch elementType {
            case 0, 1, 7: stride = 1
            case 2, 3: stride = 2
            case 4, 5, 6: stride = 4
            case 10, 11, 12: stride = 8
            default: stride = 0
            }
            if stride > 0 { offset += count * stride }
        }
    }
}
