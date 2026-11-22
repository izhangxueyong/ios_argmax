import Foundation
import SherpaOnnx

// MARK: - Bundled on-device intelligence models
//
// Four extra checkpoints are shipped inside the app bundle (no runtime
// download). All three ONNX models share the sherpa-onnx runtime:
//
//   sense-voice/model.int8.onnx + tokens.txt  -> 端侧多语种识别
//   silero_vad.int8.onnx                     -> 语音区间（细进度条）
//   campplus/3dspeaker_..._advanced.onnx     -> 声纹，判断「是不是我」
//   embeddinggemma-300M-Q8_0.gguf            -> 归档语义搜索（见 GGUFEmbedding.swift）
//
// Everything degrades gracefully: if a checkpoint is missing, the caller gets
// an explicit note in the log and an energy-based fallback timeline instead
// of a crash. That matters because the CI simulator has no microphone and the
// demo must always reach the end of the recording.

public struct VoiceSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var isMe: Bool
    public var similarity: Double

    // Swift's synthesized memberwise init is `internal`, so the app target
    // cannot see it across the module boundary (it would only find the
    // Decodable `init(from:)`). Declare the ones we expose explicitly.
    public init(start: Double, end: Double, isMe: Bool, similarity: Double) {
        self.start = start
        self.end = end
        self.isMe = isMe
        self.similarity = similarity
    }
}

public struct AudioAnalysis: Codable, Equatable, Sendable {
    public var duration: Double
    public var segments: [VoiceSegment]
    public var speakerDimension: Int
    public var engineNote: String

    public init(duration: Double, segments: [VoiceSegment], speakerDimension: Int, engineNote: String) {
        self.duration = duration
        self.segments = segments
        self.speakerDimension = speakerDimension
        self.engineNote = engineNote
    }
}

public struct SearchHit: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var snippet: String
    public var score: Double

    public init(id: String, title: String, snippet: String, score: Double) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.score = score
    }
}

public struct IndexedDocument: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var vector: [Float]

    public init(id: String, title: String, text: String, vector: [Float]) {
        self.id = id
        self.title = title
        self.text = text
        self.vector = vector
    }
}

public final class AudioIntelligence: @unchecked Sendable {
    public static let shared = AudioIntelligence()

    /// Similarity threshold for "this voice segment is me".
    public static let speakerThreshold: Double = 0.62

    private var vadPath: String = ""
    private var campplusPath: String = ""
    private var senseVoicePath: String = ""
    private var senseVoiceTokensPath: String = ""
    private var ggufURL: URL?
    private var encoder: GGUFEmbeddingEncoder?
    private var referenceVector: [Float] = []
    private var didConfigure = false
    // Loading the 228 MB SenseVoice and 28 MB CAMPPlus graphs on every clip is
    // expensive, so keep one instance of each for the whole app session.
    private var cachedRecognizer: SherpaOnnxOfflineRecognizer?
    private var cachedSpeakerExtractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper?

    public private(set) var statusLines: [String] = []

    // MARK: - Runtime-configurable inference parameters
    //
    // Defaults are byte-for-byte identical to the previously hardcoded values,
    // so an untouched build behaves exactly as before. The "模式和模型" screen
    // writes these scalars through ModelTuningStore.applyToAudioIntelligence.
    // Mutating a SenseVoice parameter invalidates the cached 228 MB graph so
    // the next call really rebuilds it with the new setting.
    public var vadThreshold: Float = 0.45
    public var vadMinSilenceDuration: Float = 0.20
    public var vadMinSpeechDuration: Float = 0.15
    public var vadWindowSize: Int = 512
    public var vadMaxSpeechDuration: Float = 8.0
    public var speakerSimilarityThreshold: Double = 0.62
    public var senseVoiceLanguageSetting: String = "auto" {
        didSet { cachedRecognizer = nil }
    }
    public var senseVoiceUseITN: Bool = true {
        didSet { cachedRecognizer = nil }
    }
    public var senseVoiceThreadCount: Int = 2 {
        didSet { cachedRecognizer = nil }
    }
    public var searchResultLimit: Int = 8

    private init() {}

    public var encoderInfo: String {
        guard let info = encoder?.info else { return "EmbeddingGemma 未加载" }
        return "EmbeddingGemma \(info.architecture) · \(info.dimension) 维 · 词表 \(info.tokenCount) · \(info.blockCount) 层"
    }

    public var registeredVoiceDimension: Int { referenceVector.count }

    public func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        let folder = Self.modelsFolder()
        let fileManager = FileManager.default
        let names = [
            "sense-voice/model.int8.onnx",
            "sense-voice/tokens.txt",
            "silero_vad.int8.onnx",
            "campplus/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
            "embeddinggemma-300M-Q8_0.gguf"
        ]
        for name in names {
            let url = folder.appendingPathComponent(name)
            let exists = fileManager.fileExists(atPath: url.path)
            var size = 0
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let number = attributes[.size] as? NSNumber {
                size = number.intValue
            }
            statusLines.append("\(exists ? "OK" : "MISSING") \(name) \(size) bytes")
        }
        vadPath = folder.appendingPathComponent("silero_vad.int8.onnx").path
        campplusPath = folder.appendingPathComponent("campplus/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx").path
        senseVoicePath = folder.appendingPathComponent("sense-voice/model.int8.onnx").path
        senseVoiceTokensPath = folder.appendingPathComponent("sense-voice/tokens.txt").path
        ggufURL = folder.appendingPathComponent("embeddinggemma-300M-Q8_0.gguf")

        if let url = ggufURL, fileManager.fileExists(atPath: url.path) {
            encoder = GGUFEmbeddingEncoder(fileURL: url)
            statusLines.append(encoder == nil ? "GGUF parse FAILED" : "GGUF encoder ready: \(encoderInfo)")
        } else {
            statusLines.append("GGUF encoder skipped: file missing")
        }
        statusLines.append("sherpa-onnx \(getSherpaOnnxVersion())")
    }

    private static func modelsFolder() -> URL {
        if let url = Bundle.main.url(forResource: "ai-models", withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) { return url }
        let nested = Bundle.main.bundleURL.appendingPathComponent("Models/ai-models", isDirectory: true)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        return Bundle.main.bundleURL.appendingPathComponent("ai-models", isDirectory: true)
    }

    // MARK: - Mock voice enrollment

    /// "Register my voice" using the bundled reference utterance. This is a
    /// simulated enrollment: a real app would record 3 utterances from the
    /// user and average their CAMPPlus embeddings.
    public func enrollMockVoice() {
        configure()
        guard referenceVector.isEmpty,
              let url = Bundle.main.url(forResource: "recording", withExtension: "wav")
                ?? Bundle.main.url(forResource: "recording", withExtension: "wav", subdirectory: "Resources"),
              let samples = Self.readWAV16k(url: url) else {
            statusLines.append("voice enrollment: sample audio missing")
            return
        }
        let vector = speakerEmbedding(samples)
        guard !vector.isEmpty else {
            statusLines.append("voice enrollment: CAMPPlus returned empty vector")
            return
        }
        referenceVector = vector
        statusLines.append("mock voice enrolled: CAMPPlus \(vector.count)-d vector from bundled sample")
    }

    // MARK: - Timeline: VAD segments + per-segment speaker verification

    public func analyze(audioURL: URL) -> AudioAnalysis {
        configure()
        guard let samples = Self.readWAV16k(url: audioURL) else {
            return AudioAnalysis(duration: 0, segments: [], speakerDimension: 0, engineNote: "WAV 读取失败")
        }
        let duration = Double(samples.count) / 16_000.0
        var ranges = vadSegments(samples: samples)
        var note = "Silero VAD"
        if ranges.isEmpty {
            ranges = Self.energySegments(samples: samples)
            note = "能量检测（Silero VAD 未返回语音段）"
        }
        if referenceVector.isEmpty { enrollMockVoice() }

        var segments: [VoiceSegment] = []
        for range in ranges {
            let start = Double(range.0) / 16_000.0
            let end = Double(min(range.1, samples.count)) / 16_000.0
            let slice = Array(samples[range.0..<min(range.1, samples.count)])
            let vector = speakerEmbedding(slice)
            let score: Double
            if vector.isEmpty || referenceVector.isEmpty {
                score = 0
            } else {
                score = Double(Self.cosine(vector, referenceVector))
            }
            segments.append(VoiceSegment(
                start: start,
                end: max(end, start + 0.01),
                isMe: score >= speakerSimilarityThreshold,
                similarity: score
            ))
        }
        let dimension = referenceVector.count
        note += " · CAMPPlus \(segments.filter(\.isMe).count)/\(segments.count) 段判为「我」"
        return AudioAnalysis(
            duration: duration,
            segments: segments,
            speakerDimension: dimension,
            engineNote: note
        )
    }

    // MARK: - SenseVoice offline recognition

    public func senseVoiceTranscribe(audioURL: URL) -> (text: String, language: String, note: String) {
        configure()
        guard let samples = Self.readWAV16k(url: audioURL), !samples.isEmpty,
              let recognizer = ensureRecognizer() else {
            return ("", "", "SenseVoice 模型或音频不可用")
        }
        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        let setting = "SenseVoiceSmall int8 · lang=\(senseVoiceLanguageSetting) · itn=\(senseVoiceUseITN ? "on" : "off") · threads=\(senseVoiceThreadCount)"
        return (result.text, result.lang, setting)
    }

    private func ensureRecognizer() -> SherpaOnnxOfflineRecognizer? {
        if let cachedRecognizer { return cachedRecognizer }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: senseVoicePath),
              fileManager.fileExists(atPath: senseVoiceTokensPath) else { return nil }
        let sense = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: senseVoicePath,
            language: senseVoiceLanguageSetting,
            useInverseTextNormalization: senseVoiceUseITN
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: senseVoiceTokensPath,
            numThreads: senseVoiceThreadCount,
            provider: "cpu",
            debug: 0,
            senseVoice: sense
        )
        let feature = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: feature, modelConfig: modelConfig)
        let recognizer = withUnsafePointer(to: &config) { pointer in
            SherpaOnnxOfflineRecognizer(config: pointer)
        }
        cachedRecognizer = recognizer
        statusLines.append("SenseVoice recognizer loaded once (228 MB int8 graph)")
        return recognizer
    }

    // MARK: - Text embedding / semantic search

    public func buildIndex(from documents: [(id: String, title: String, text: String)]) -> [IndexedDocument] {
        configure()
        guard let encoder else { return [] }
        return documents.map { document in
            IndexedDocument(
                id: document.id,
                title: document.title,
                text: document.text,
                vector: encoder.encode(document.text)
            )
        }
    }

    /// `limit == nil` uses the runtime-configurable `searchResultLimit`
    /// (managed by the "模式和模型" screen); an explicit limit still wins.
    public func search(query: String, in documents: [IndexedDocument], limit: Int? = nil) -> [SearchHit] {
        configure()
        guard let encoder, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let queryVector = encoder.encode(query)
        let effectiveLimit = max(1, limit ?? searchResultLimit)
        return documents
            .map { document in
                SearchHit(
                    id: document.id,
                    title: document.title,
                    snippet: String(document.text.prefix(90)),
                    score: Double(GGUFEmbeddingEncoder.cosine(queryVector, document.vector))
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(effectiveLimit)
            .map { $0 }
    }

    // MARK: - sherpa-onnx primitives

    private func vadSegments(samples: [Float]) -> [(Int, Int)] {
        guard FileManager.default.fileExists(atPath: vadPath) else { return [] }
        let silero = sherpaOnnxSileroVadModelConfig(
            model: vadPath,
            threshold: vadThreshold,
            minSilenceDuration: vadMinSilenceDuration,
            minSpeechDuration: vadMinSpeechDuration,
            windowSize: vadWindowSize,
            maxSpeechDuration: vadMaxSpeechDuration
        )
        var config = sherpaOnnxVadModelConfig(
            sileroVad: silero,
            sampleRate: 16_000,
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        var ranges: [(Int, Int)] = []
        withUnsafePointer(to: &config) { pointer in
            let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: pointer, buffer_size_in_seconds: 30)
            var index = 0
            let window = max(32, vadWindowSize)
            while index < samples.count {
                let count = min(window, samples.count - index)
                vad.acceptWaveform(samples: Array(samples[index..<(index + count)]))
                index += count
                drain(vad, into: &ranges)
            }
            vad.flush()
            drain(vad, into: &ranges)
        }
        return ranges
    }

    private func drain(_ vad: SherpaOnnxVoiceActivityDetectorWrapper, into ranges: inout [(Int, Int)]) {
        while !vad.isEmpty() {
            let segment = vad.front()
            let start = segment.start
            let end = start + segment.n
            if end > start { ranges.append((start, end)) }
            vad.pop()
        }
    }

    private func speakerEmbedding(_ samples: [Float]) -> [Float] {
        guard samples.count >= 4_000, let extractor = ensureSpeakerExtractor() else { return [] }
        // CAMPPlus needs a reasonable amount of speech; pad short segments.
        var input = samples
        if input.count < 16_000 {
            input.append(contentsOf: Array(samples.prefix(min(samples.count, 16_000 - input.count))))
        }
        let stream = extractor.createStream()
        stream.acceptWaveform(samples: input, sampleRate: 16_000)
        stream.inputFinished()
        return extractor.compute(stream: stream)
    }

    private func ensureSpeakerExtractor() -> SherpaOnnxSpeakerEmbeddingExtractorWrapper? {
        if let cachedSpeakerExtractor { return cachedSpeakerExtractor }
        guard FileManager.default.fileExists(atPath: campplusPath) else { return nil }
        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: campplusPath,
            numThreads: 1,
            debug: 0,
            provider: "cpu"
        )
        let extractor = withUnsafePointer(to: &config) { pointer in
            SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: pointer)
        }
        guard extractor.impl != nil else { return nil }
        cachedSpeakerExtractor = extractor
        statusLines.append("CAMPPlus extractor loaded once (28 MB graph), dim=\(extractor.dim)")
        return extractor
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    private static func energySegments(samples: [Float]) -> [(Int, Int)] {
        let window = 1_600 // 0.1s
        var energies: [Double] = []
        var index = 0
        while index < samples.count {
            let count = min(window, samples.count - index)
            var sum: Double = 0
            for i in index..<(index + count) { sum += Double(samples[i]) * Double(samples[i]) }
            energies.append(sqrt(sum / Double(max(count, 1))))
            index += window
        }
        let peak = energies.max() ?? 0
        let threshold = max(peak * 0.25, 0.005)
        var ranges: [(Int, Int)] = []
        var currentStart: Int?
        for (i, energy) in energies.enumerated() {
            if energy > threshold {
                if currentStart == nil { currentStart = i * window }
            } else if let start = currentStart {
                ranges.append((start, i * window))
                currentStart = nil
            }
        }
        if let start = currentStart { ranges.append((start, samples.count)) }
        return ranges
    }

    // MARK: - Minimal 16 kHz mono PCM WAV reader

    public static func readWAV16k(url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        func le16(_ i: Int) -> Int { Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
        func le32(_ i: Int) -> Int {
            Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
        }
        guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        var cursor = 12
        var channels = 1, sampleRate = 16_000, bits = 16
        var dataStart = 0, dataLength = 0
        while cursor + 8 <= bytes.count {
            let name = String(decoding: bytes[cursor..<(cursor + 4)], as: UTF8.self)
            let size = le32(cursor + 4)
            let body = cursor + 8
            if name == "fmt " && body + 16 <= bytes.count {
                let format = le16(body)
                channels = le16(body + 2)
                sampleRate = le32(body + 4)
                bits = le16(body + 14)
                if format != 1 { return nil }
            } else if name == "data" {
                dataStart = body
                dataLength = min(size, bytes.count - body)
                break
            }
            guard size > 0 else { break }
            cursor = body + size + (size % 2)
        }
        guard dataStart > 0, dataLength > 0, channels > 0, bits >= 8 else { return nil }
        let bytesPerSample = bits / 8
        let frameCount = dataLength / (bytesPerSample * channels)
        var mono: [Float] = []
        mono.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                let p = dataStart + (frame * channels + channel) * bytesPerSample
                guard p + bytesPerSample <= bytes.count else { break }
                switch bits {
                case 8:
                    sum += (Float(bytes[p]) - 128.0) / 128.0
                case 16:
                    let raw = Int16(bitPattern: UInt16(le16(p)))
                    sum += Float(raw) / 32_768.0
                case 32:
                    let raw = Int32(bitPattern: UInt32(le32(p)))
                    sum += Float(raw) / 2_147_483_648.0
                default:
                    let raw = Int16(bitPattern: UInt16(le16(p)))
                    sum += Float(raw) / 32_768.0
                }
            }
            mono.append(sum / Float(channels))
        }
        guard sampleRate == 16_000 else {
            let ratio = Double(sampleRate) / 16_000.0
            let outCount = Int(Double(mono.count) / ratio)
            var resampled: [Float] = []
            resampled.reserveCapacity(outCount)
            for i in 0..<outCount {
                let position = Double(i) * ratio
                let lower = Int(position)
                let fraction = Float(position - Double(lower))
                let a = mono[min(lower, mono.count - 1)]
                let b = mono[min(lower + 1, mono.count - 1)]
                resampled.append(a + (b - a) * fraction)
            }
            return resampled
        }
        return mono
    }
}
