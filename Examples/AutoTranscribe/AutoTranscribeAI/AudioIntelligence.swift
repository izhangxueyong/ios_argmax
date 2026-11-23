import Foundation
import Darwin
import SherpaOnnx

// MARK: - iOS 上最高效的 ONNX 推理引擎
//
// ONNX Runtime Mobile 的 CoreML Execution Provider 会把 ONNX 子图交给
// Core ML，由系统调度到 Apple Neural Engine / GPU / CPU，官方描述为
// "in the most efficient way in order to maximize performance while
// minimizing memory and power consumption"。sherpa-onnx 底层就是 ORT，
// provider 参数直接决定走哪条执行路径。
//
// 三个可选引擎，都会被真实传给 sherpaOnnxOfflineModelConfig(provider:)：
//   auto   真机优先 CoreML EP（ANE），模拟器/不可用时安全回退 CPU EP
//   cpu    ORT CPU EP（XNNPACK / ARM NEON int8），全平台稳定
//   coreml ORT CoreML EP → Apple Neural Engine，iOS 上最快
public enum OnnxInferenceEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case cpu
    case coreML

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动 · 真机优先 ANE"
        case .cpu: return "ONNX Runtime · CPU EP"
        case .coreML: return "ONNX Runtime · CoreML EP"
        }
    }

    public var badge: String {
        switch self {
        case .auto: return "推荐"
        case .cpu: return "稳定"
        case .coreML: return "iOS 最高效"
        }
    }

    public var summary: String {
        switch self {
        case .auto: return "真机自动启用 CoreML EP 交给 ANE；iOS Simulator 无 ANE 时自动回退 CPU EP。"
        case .cpu: return "ORT CPU EP，int8 量化图在 XNNPACK / ARM NEON 上执行，所有设备可用。"
        case .coreML: return "把 ONNX 子图编译成 MLProgram，交给 Core ML 调度到 Apple Neural Engine。"
        }
    }

    public var speedNote: String {
        switch self {
        case .auto: return "真机取最快路径，无需手动切换"
        case .cpu: return "基准；SenseVoiceSmall int8 在 A12X 上约 15.6 tok/s"
        case .coreML: return "同 int8 模型实测 8ms vs TFLite 188ms（≈23×）；SenseVoice ANE 版比 ONNX CPU 快 2–7×"
        }
    }

    public var requirement: String {
        switch self {
        case .auto: return "iOS 13+；ANE 需真机 A12+ / iOS 15+（MLProgram）"
        case .cpu: return "无额外要求，模拟器与真机均可"
        case .coreML: return "需真机 + CoreML 框架 + 带 --use_coreml 编译的 ORT"
        }
    }

    public var sourceTrace: String {
        "AudioIntelligence.swift · resolveOnnxEngine / ensureRecognizer"
    }
}

/// 一次引擎解析的完整可审计结果：请求值、实际生效值、回退原因与环境证据。
public struct OnnxRuntimeStatus: Codable, Equatable, Sendable {
    public var requested: String
    public var effectiveProvider: String
    public var reason: String
    public var simulator: Bool
    public var coreMLFrameworkAvailable: Bool
    public var ortCoreMLSymbolFound: Bool
    public var aneEligible: Bool
    public var sherpaVersion: String
    public var resolvedAt: Date

    public init(requested: String, effectiveProvider: String, reason: String,
                simulator: Bool, coreMLFrameworkAvailable: Bool,
                ortCoreMLSymbolFound: Bool, aneEligible: Bool,
                sherpaVersion: String, resolvedAt: Date) {
        self.requested = requested
        self.effectiveProvider = effectiveProvider
        self.reason = reason
        self.simulator = simulator
        self.coreMLFrameworkAvailable = coreMLFrameworkAvailable
        self.ortCoreMLSymbolFound = ortCoreMLSymbolFound
        self.aneEligible = aneEligible
        self.sherpaVersion = sherpaVersion
        self.resolvedAt = resolvedAt
    }

    public var displayProvider: String {
        effectiveProvider == "coreml" ? "coreml（CoreML EP → ANE）" : "cpu（CPU EP）"
    }
}

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
    /// 由「模型链」预设控制：关闭后 analyze() 只做 VAD 分段，不再调用 CAMPPlus。
    public var enableSpeakerVerification: Bool = true
    public var senseVoiceLanguageSetting: String = "auto" {
        didSet { cachedRecognizer = nil }
    }
    public var senseVoiceUseITN: Bool = true {
        didSet { cachedRecognizer = nil }
    }
    public var senseVoiceThreadCount: Int = 2 {
        didSet { cachedRecognizer = nil }
    }
    /// 「模式和模型」页所选的 ONNX 执行引擎。切换后三个 ONNX 会话缓存全部
    /// 失效，下一次调用会按新 provider 真实重建 ORT session。
    public var onnxEngineRaw: String = OnnxInferenceEngine.auto.rawValue {
        didSet {
            guard oldValue != onnxEngineRaw else { return }
            cachedRecognizer = nil
            cachedSpeakerExtractor = nil
        }
    }
    /// 最近一次解析的引擎结果与回退原因，管理页与调用日志直接读取。
    public private(set) var onnxRuntimeStatus: OnnxRuntimeStatus?
    public var searchResultLimit: Int = 8

    // MARK: - ONNX 引擎解析（真实生效 + 安全回退）

    /// 尽力探测 ORT 是否链接了 CoreML EP 入口。静态库符号不一定出现在动态
    /// 符号表，所以该字段只作为诊断证据，不作为能否启用 ANE 的硬门槛。
    private static func ortCoreMLSymbolPresent() -> Bool {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, "OrtSessionOptionsAppendExecutionProvider_CoreML") != nil
            || dlsym(handle, "OrtSessionOptionsAppendExecutionProvider") != nil
    }

    /// 把用户在管理页选择的引擎解析成真正传给 sherpa-onnx 的 provider。
    /// iOS Simulator 没有 ANE，且 ORT 的 CoreML EP 不参与模拟器运算，
    /// 因此模拟器上一律安全回退 cpu，并把「请求 / 生效 / 原因」全部记录。
    @discardableResult
    public func resolveOnnxEngine() -> String {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        // CoreML 是 iOS 系统框架，编译期必定可用；运行时以「是否模拟器」为准。
        // NSClassFromString("MLModel") 在真机上也可能因 Swift 类名 mangling
        // 返回 nil，因此不能拿它当能否启用 ANE 的硬门槛。
        #if canImport(CoreML)
        let coreMLFramework = true
        #else
        let coreMLFramework = false
        #endif
        let symbol = Self.ortCoreMLSymbolPresent()
        // 真机 + CoreML 框架可用即认为具备 ANE 路径；ORT 若未编入 CoreML EP
        // 会自行忽略该 provider 并在 CPU 上执行，不会让 session 创建失败。
        let aneEligible = !simulator && coreMLFramework
        let requested = OnnxInferenceEngine(rawValue: onnxEngineRaw) ?? .auto

        let effective: String
        let reason: String
        switch requested {
        case .cpu:
            effective = "cpu"
            reason = "显式选择 CPU EP：ORT 在 XNNPACK / ARM NEON 上执行 int8 图，模拟器与真机均可用。"
        case .coreML:
            if aneEligible {
                effective = "coreml"
                reason = "真机具备 ANE，ORT CoreML EP 已启用：ONNX 子图交给 Core ML 调度到 Neural Engine。"
            } else {
                effective = "cpu"
                reason = simulator
                    ? "已请求 CoreML EP，但 iOS Simulator 无 Apple Neural Engine，ORT CoreML EP 不可用 → 安全回退 CPU EP。"
                    : "已请求 CoreML EP，但当前运行时不具备 CoreML 框架 → 安全回退 CPU EP。"
            }
        case .auto:
            if aneEligible {
                effective = "coreml"
                reason = "自动：真机 + CoreML 框架可用 → 选用最高效的 CoreML EP（ANE）路径。"
            } else {
                effective = "cpu"
                reason = simulator
                    ? "自动：iOS Simulator 无 ANE → 回退 CPU EP；同一 App 装到真机会自动切到 CoreML EP。"
                    : "自动：未检测到可用 CoreML 框架 → 回退 CPU EP。"
            }
        }

        let version = getSherpaOnnxVersion()
        let status = OnnxRuntimeStatus(
            requested: requested.rawValue,
            effectiveProvider: effective,
            reason: reason,
            simulator: simulator,
            coreMLFrameworkAvailable: coreMLFramework,
            ortCoreMLSymbolFound: symbol,
            aneEligible: aneEligible,
            sherpaVersion: version,
            resolvedAt: Date()
        )
        onnxRuntimeStatus = status
        let line = "ONNX ENGINE requested=\(requested.rawValue) effective=\(effective) simulator=\(simulator) coreMLFramework=\(coreMLFramework) ortCoreMLSymbol=\(symbol) aneEligible=\(aneEligible) sherpa=\(version) reason=\(reason)"
        if !statusLines.contains(line) { statusLines.append(line) }
        return effective
    }

    /// 给调用日志与 UI 用的引擎快照字段。
    public var onnxEngineSnapshot: [String: String] {
        let status = onnxRuntimeStatus
        return [
            "ONNX 引擎": (OnnxInferenceEngine(rawValue: onnxEngineRaw) ?? .auto).title,
            "请求 provider": status?.requested ?? onnxEngineRaw,
            "实际生效 provider": status?.effectiveProvider ?? "cpu",
            "引擎解析原因": status?.reason ?? "尚未解析",
            "运行环境": (status?.simulator ?? true) ? "iOS Simulator（无 ANE）" : "iOS 真机"
        ]
    }

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
        if !enableSpeakerVerification {
            let vadOnly: [VoiceSegment] = ranges.map { range in
                let start = Double(range.0) / 16_000.0
                let end = Double(min(range.1, samples.count)) / 16_000.0
                return VoiceSegment(start: start, end: max(end, start + 0.01),
                                    isMe: false, similarity: 0)
            }
            return AudioAnalysis(duration: duration, segments: vadOnly, speakerDimension: 0,
                                 engineNote: note + " · CAMPPlus 已按模型链关闭")
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
        let engine = OnnxInferenceEngine(rawValue: onnxEngineRaw) ?? .auto
        let effective = onnxRuntimeStatus?.effectiveProvider ?? "cpu"
        let setting = "SenseVoiceSmall int8 · engine=\(engine.title) provider=\(effective) · lang=\(senseVoiceLanguageSetting) · itn=\(senseVoiceUseITN ? "on" : "off") · threads=\(senseVoiceThreadCount)"
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
            provider: resolveOnnxEngine(),
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
            provider: resolveOnnxEngine(),
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
            provider: resolveOnnxEngine()
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
