//  ModelManagement.swift
//  "模式和模型" 管理：模型注册表、模式→模型映射、可编辑且生效的推理参数、
//  结构化调用日志，以及一个五分段的管理界面。
//
//  设计原则（与本项目其它部分一致）：
//   * 全部数据来自真实源码与真实运行时，不做静态假数据。
//   * 每个模型都标注"参数定义在哪个文件的哪个函数"，便于源码追溯。
//   * 参数不是摆设：Whisper 解码参数经 TranscriptionService.makeOptions 生效；
//     VAD / 声纹 / SenseVoice / 搜索参数经 AudioIntelligence 公开属性生效。
//   * 每次调用（转写 / 重转 / VAD / 声纹 / SenseVoice / 向量索引 / 语义搜索）
//     都把当时的参数快照写进 ModelCallLog，持久化到 Documents/model_calls.json。
//   * 默认值与改造前的硬编码值完全一致，因此 CI 已验证的转写结果不会变化。

import AutoTranscribeAI
import Foundation
import SwiftUI

// MARK: - 管理界面分段

enum ManagementSection: String, CaseIterable, Identifiable {
    case overview
    case models
    case bindings
    case tuning
    case calls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .models: return "模型"
        case .bindings: return "模式"
        case .tuning: return "参数"
        case .calls: return "日志"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "chart.pie"
        case .models: return "square.stack.3d.up"
        case .bindings: return "arrow.triangle.branch"
        case .tuning: return "slider.horizontal.3"
        case .calls: return "list.bullet.rectangle"
        }
    }
}

// MARK: - 模型注册表

enum ModelRole: String, Codable, Sendable {
    case primaryASR
    case secondaryASR
    case vad
    case speaker
    case embedding

    var title: String {
        switch self {
        case .primaryASR: return "主转写 ASR"
        case .secondaryASR: return "二次识别"
        case .vad: return "语音活动检测"
        case .speaker: return "声纹判定"
        case .embedding: return "文本向量"
        }
    }
}

struct ModelDescriptor: Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let engine: String
    let format: String
    /// 相对 app bundle 根的路径。CI 打包后可能是 <root>/<path> 或 <root>/Models/<path>。
    let bundlePath: String
    let isDirectory: Bool
    let expectedBytes: Int64
    let dimensionNote: String
    let role: ModelRole
    let usedIn: String
    let purpose: String
    /// 参数定义位置，便于从界面直接回到源码。
    let sourceTrace: String

    var expectedSizeText: String {
        if expectedBytes >= 1_000_000 {
            return String(format: "%.0f MB", Double(expectedBytes) / 1_000_000)
        }
        return String(format: "%.0f KB", Double(expectedBytes) / 1_000)
    }
}

struct ModelRuntimeStatus: Sendable {
    let exists: Bool
    let bytes: Int64
    let fileCount: Int
    let resolvedPath: String
}

enum ModelRegistry {
    /// 顺序即界面展示顺序：先两个主 ASR，再四个端侧辅助模型。
    static let models: [ModelDescriptor] = [
        ModelDescriptor(
            id: "whisper-base",
            name: "Whisper Base",
            version: "openai_whisper-base",
            engine: "Argmax WhisperKit · Core ML",
            format: ".mlmodelc 目录",
            bundlePath: "whisper-base",
            isDirectory: true,
            expectedBytes: 74_000_000,
            dimensionNote: "99 种识别语言（不含粤语）",
            role: .primaryASR,
            usedIn: "仅普通模式",
            purpose: "普通模式主转写。CPU-only 模拟器上放宽质量阈值、无时间戳解码，避免 special token 残流。",
            sourceTrace: "TranscriptionService.swift · makeOptions / relaxQualityThresholds"
        ),
        ModelDescriptor(
            id: "whisper-turbo",
            name: "Whisper Large-v3 Turbo",
            version: "openai_whisper-large-v3-v20240930_turbo",
            engine: "Argmax WhisperKit · Core ML",
            format: ".mlmodelc 目录",
            bundlePath: "whisper-turbo",
            isDirectory: true,
            expectedBytes: 632_000_000,
            dimensionNote: "100 种识别语言（含粤语 yue）",
            role: .primaryASR,
            usedIn: "仅精准模式",
            purpose: "精准模式主转写。使用默认质量阈值与带时间戳解码，输出更完整。",
            sourceTrace: "TranscriptionService.swift · makeOptions / loadKit"
        ),
        ModelDescriptor(
            id: "sense-voice",
            name: "SenseVoiceSmall int8",
            version: "sherpa-onnx SenseVoice",
            engine: "sherpa-onnx · ONNX Runtime",
            format: "int8 ONNX + tokens.txt",
            bundlePath: "ai-models/sense-voice/model.int8.onnx",
            isDirectory: false,
            expectedBytes: 228_000_000,
            dimensionNote: "多语种 · auto 语言检测",
            role: .secondaryASR,
            usedIn: "普通 + 精准",
            purpose: "对同一段音频做端侧二次识别，与 Whisper 结果并列展示，用于交叉核对。",
            sourceTrace: "AudioIntelligence.swift · senseVoiceTranscribe"
        ),
        ModelDescriptor(
            id: "silero-vad",
            name: "Silero VAD int8",
            version: "sherpa-onnx Silero VAD",
            engine: "sherpa-onnx · ONNX Runtime",
            format: "int8 ONNX",
            bundlePath: "ai-models/silero_vad.int8.onnx",
            isDirectory: false,
            expectedBytes: 208_000,
            dimensionNote: "512 采样点窗口 · 16 kHz",
            role: .vad,
            usedIn: "普通 + 精准",
            purpose: "切出语音区间，绘制每条录音下方的细进度条（灰=静音）。",
            sourceTrace: "AudioIntelligence.swift · vadSegments"
        ),
        ModelDescriptor(
            id: "campplus",
            name: "CAMPPlus 声纹",
            version: "3dspeaker_speech_campplus_sv_zh_en_16k",
            engine: "sherpa-onnx · ONNX Runtime",
            format: "ONNX",
            bundlePath: "ai-models/campplus/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
            isDirectory: false,
            expectedBytes: 28_280_000,
            dimensionNote: "192 维声纹向量 · 余弦相似度",
            role: .speaker,
            usedIn: "普通 + 精准",
            purpose: "把每个 VAD 语音段与模拟注册的「我的声纹」比较，判定绿色=我 / 橙色=他人。",
            sourceTrace: "AudioIntelligence.swift · analyze / speakerEmbedding"
        ),
        ModelDescriptor(
            id: "embeddinggemma",
            name: "EmbeddingGemma Q8_0",
            version: "gemma-embedding · GGUF v3",
            engine: "纯 Swift GGUF 读取（无推理框架）",
            format: "Q8_0 GGUF",
            bundlePath: "ai-models/embeddinggemma-300M-Q8_0.gguf",
            isDirectory: false,
            expectedBytes: 334_000_000,
            dimensionNote: "768 维 · 24 层 · 262144 词表",
            role: .embedding,
            usedIn: "普通 + 精准",
            purpose: "读取 token_embd.weight 做均值池化 + L2 归一化，为归档生成句向量并按余弦相似度检索。",
            sourceTrace: "GGUFEmbedding.swift · GGUFEmbeddingEncoder.encode / cosine"
        )
    ]

    static func descriptor(_ id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }

    /// 运行时真实检查：文件是否存在、实际字节数、目录内文件数。
    static func runtimeStatus(_ descriptor: ModelDescriptor) -> ModelRuntimeStatus {
        let fm = FileManager.default
        let root = Bundle.main.bundleURL
        let candidates: [URL] = [
            root.appendingPathComponent(descriptor.bundlePath, isDirectory: descriptor.isDirectory),
            root.appendingPathComponent("Models/" + descriptor.bundlePath, isDirectory: descriptor.isDirectory)
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            if descriptor.isDirectory {
                var count = 0
                var bytes: Int64 = 0
                if let enumerator = fm.enumerator(atPath: url.path) {
                    while let entry = enumerator.nextObject() as? String {
                        count += 1
                        let child = url.appendingPathComponent(entry)
                        if let attrs = try? fm.attributesOfItem(atPath: child.path),
                           let n = attrs[.size] as? NSNumber {
                            bytes += n.int64Value
                        }
                    }
                }
                return ModelRuntimeStatus(exists: true, bytes: bytes, fileCount: count, resolvedPath: url.lastPathComponent)
            }
            let number = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            return ModelRuntimeStatus(
                exists: true,
                bytes: number?.int64Value ?? 0,
                fileCount: 1,
                resolvedPath: url.lastPathComponent
            )
        }
        return ModelRuntimeStatus(exists: false, bytes: 0, fileCount: 0, resolvedPath: "未找到")
    }

    static var totalExpectedBytes: Int64 {
        var total: Int64 = 0
        for model in models { total += model.expectedBytes }
        return total
    }
}

// MARK: - 模式 → 模型映射

struct ModeBinding: Identifiable, Sendable {
    let id: String
    let modeTitle: String
    let modeRaw: String
    let primaryModelID: String
    let languageCount: Int
    let languageNote: String
    let decodingNote: String
    /// 一次完整录音后依次经过的辅助模型 id。
    let pipelineIDs: [String]
    let sourceTrace: String
}

enum ModeBindingRegistry {
    static let bindings: [ModeBinding] = [
        ModeBinding(
            id: "standard",
            modeTitle: "普通模式",
            modeRaw: "standard",
            primaryModelID: "whisper-base",
            languageCount: 99,
            languageNote: "自动检测 + 99 种识别语言（Whisper 原始 tokenizer，无 yue）",
            decodingNote: "temperature 0.0 · withoutTimestamps=true · 放宽 noSpeech/logProb/compressionRatio 阈值 · 无效结果同模型 fallback 重试",
            pipelineIDs: ["silero-vad", "campplus", "sense-voice", "embeddinggemma"],
            sourceTrace: "LanguageCatalog.baseTargets · TranscriptionService.makeOptions"
        ),
        ModeBinding(
            id: "precise",
            modeTitle: "精准模式",
            modeRaw: "precise",
            primaryModelID: "whisper-turbo",
            languageCount: 100,
            languageNote: "自动检测 + 100 种识别语言（large-v3-turbo 含粤语 yue）",
            decodingNote: "temperature 0.0 · 带时间戳 · WhisperKit 默认质量阈值 · 无效结果同模型 fallback 重试",
            pipelineIDs: ["silero-vad", "campplus", "sense-voice", "embeddinggemma"],
            sourceTrace: "LanguageCatalog.turboTargets · TranscriptionService.makeOptions"
        )
    ]

    /// 一次录音的完整处理链（用于界面里的流程图）。
    static let pipelineStages: [String] = [
        "录音 / 内置样本 WAV",
        "主 ASR 转写（按模式）",
        "Silero VAD 切分语音段",
        "CAMPPlus 声纹判定",
        "SenseVoice 二次识别",
        "EmbeddingGemma 建 768 维向量",
        "归档 / 语义搜索 / 备注"
    ]
}

// MARK: - 可编辑且生效的推理参数

/// 默认值与改造前各处的硬编码常量逐项一致。
struct ModelTuning: Codable, Equatable, Sendable {
    // Whisper 解码
    var temperature: Double = 0.0
    var fallbackTemperature: Double = 0.2
    var temperatureFallbackCount: Int = 5
    var fallbackCount: Int = 3
    var baseWithoutTimestamps: Bool = true
    var baseRelaxQualityThresholds: Bool = true
    var skipSpecialTokens: Bool = true
    // Silero VAD
    var vadThreshold: Double = 0.45
    var vadMinSilence: Double = 0.20
    var vadMinSpeech: Double = 0.15
    var vadWindowSize: Int = 512
    var vadMaxSpeech: Double = 8.0
    // CAMPPlus
    var speakerThreshold: Double = 0.62
    // SenseVoice
    var senseVoiceLanguage: String = "auto"
    var senseVoiceITN: Bool = true
    var senseVoiceThreads: Int = 2
    // 语义搜索
    var searchLimit: Int = 8

    static let defaults = ModelTuning()
}

enum TuningKey: String, CaseIterable, Sendable {
    case temperature
    case fallbackTemperature
    case temperatureFallbackCount
    case fallbackCount
    case baseWithoutTimestamps
    case baseRelaxQualityThresholds
    case skipSpecialTokens
    case vadThreshold
    case vadMinSilence
    case vadMinSpeech
    case vadWindowSize
    case vadMaxSpeech
    case speakerThreshold
    case senseVoiceLanguage
    case senseVoiceITN
    case senseVoiceThreads
    case searchLimit

    var group: String {
        switch self {
        case .temperature, .fallbackTemperature, .temperatureFallbackCount,
             .fallbackCount, .baseWithoutTimestamps, .baseRelaxQualityThresholds,
             .skipSpecialTokens:
            return "Whisper 解码"
        case .vadThreshold, .vadMinSilence, .vadMinSpeech, .vadWindowSize, .vadMaxSpeech:
            return "Silero VAD"
        case .speakerThreshold:
            return "CAMPPlus 声纹"
        case .senseVoiceLanguage, .senseVoiceITN, .senseVoiceThreads:
            return "SenseVoice"
        case .searchLimit:
            return "EmbeddingGemma 搜索"
        }
    }

    var label: String {
        switch self {
        case .temperature: return "temperature（主解码）"
        case .fallbackTemperature: return "temperature（fallback）"
        case .temperatureFallbackCount: return "temperatureFallbackCount"
        case .fallbackCount: return "fallback 次数"
        case .baseWithoutTimestamps: return "Base 无时间戳解码"
        case .baseRelaxQualityThresholds: return "Base 放宽质量阈值"
        case .skipSpecialTokens: return "skipSpecialTokens"
        case .vadThreshold: return "语音判定阈值"
        case .vadMinSilence: return "最短静音时长 (s)"
        case .vadMinSpeech: return "最短语音时长 (s)"
        case .vadWindowSize: return "窗口大小 (samples)"
        case .vadMaxSpeech: return "最长语音段 (s)"
        case .speakerThreshold: return "「是我」相似度阈值"
        case .senseVoiceLanguage: return "识别语言"
        case .senseVoiceITN: return "逆文本归一化 ITN"
        case .senseVoiceThreads: return "推理线程数"
        case .searchLimit: return "返回命中条数"
        }
    }

    var hint: String {
        switch self {
        case .temperature: return "DecodingOptions.temperature；0 为贪心解码"
        case .fallbackTemperature: return "无效结果重试时使用的采样温度"
        case .temperatureFallbackCount: return "主解码的温度回退次数"
        case .fallbackCount: return "fallback 解码的温度回退次数"
        case .baseWithoutTimestamps: return "仅 Base 主解码生效，避免 >> >> >> special token 残流"
        case .baseRelaxQualityThresholds: return "置空 noSpeech / logProb / compressionRatio 阈值，避免 CPU 模拟器丢段"
        case .skipSpecialTokens: return "过滤 <|xx|> 特殊 token"
        case .vadThreshold: return "sherpaOnnxSileroVadModelConfig.threshold"
        case .vadMinSilence: return "minSilenceDuration；切分语音段的静音间隔"
        case .vadMinSpeech: return "minSpeechDuration；短于此的段被丢弃"
        case .vadWindowSize: return "windowSize；16 kHz 下需为 512 的倍数"
        case .vadMaxSpeech: return "maxSpeechDuration；超长语音强制切断"
        case .speakerThreshold: return "余弦相似度 ≥ 阈值判为「我」，进度条显示绿色"
        case .senseVoiceLanguage: return "auto / zh / en / ja / ko / yue"
        case .senseVoiceITN: return "useInverseTextNormalization，把数字/缩写规范成文本"
        case .senseVoiceThreads: return "sherpaOnnxOfflineModelConfig.numThreads"
        case .searchLimit: return "AudioIntelligence.search 返回的最大命中数"
        }
    }

    var sourceTrace: String {
        switch self {
        case .temperature, .fallbackTemperature, .temperatureFallbackCount,
             .fallbackCount, .baseWithoutTimestamps, .baseRelaxQualityThresholds,
             .skipSpecialTokens:
            return "TranscriptionService.swift · makeOptions"
        case .vadThreshold, .vadMinSilence, .vadMinSpeech, .vadWindowSize, .vadMaxSpeech:
            return "AudioIntelligence.swift · vadSegments"
        case .speakerThreshold:
            return "AudioIntelligence.swift · analyze"
        case .senseVoiceLanguage, .senseVoiceITN, .senseVoiceThreads:
            return "AudioIntelligence.swift · senseVoiceTranscribe"
        case .searchLimit:
            return "AudioIntelligence.swift · search"
        }
    }
}

struct TuningSpec: Identifiable, Sendable {
    let key: TuningKey
    let kind: Kind
    let defaultValueText: String

    enum Kind: Sendable {
        case toggle
        case slider(min: Double, max: Double, step: Double)
        case stepper(min: Int, max: Int)
        case picker([String])
    }

    var id: String { key.rawValue }
}

enum TuningCatalog {
    static let specs: [TuningSpec] = [
        TuningSpec(key: .temperature, kind: .slider(min: 0, max: 1, step: 0.1), defaultValueText: "0.00"),
        TuningSpec(key: .fallbackTemperature, kind: .slider(min: 0, max: 1, step: 0.1), defaultValueText: "0.20"),
        TuningSpec(key: .temperatureFallbackCount, kind: .stepper(min: 1, max: 10), defaultValueText: "5"),
        TuningSpec(key: .fallbackCount, kind: .stepper(min: 1, max: 10), defaultValueText: "3"),
        TuningSpec(key: .baseWithoutTimestamps, kind: .toggle, defaultValueText: "开"),
        TuningSpec(key: .baseRelaxQualityThresholds, kind: .toggle, defaultValueText: "开"),
        TuningSpec(key: .skipSpecialTokens, kind: .toggle, defaultValueText: "开"),
        TuningSpec(key: .vadThreshold, kind: .slider(min: 0, max: 1, step: 0.05), defaultValueText: "0.45"),
        TuningSpec(key: .vadMinSilence, kind: .slider(min: 0, max: 1, step: 0.05), defaultValueText: "0.20"),
        TuningSpec(key: .vadMinSpeech, kind: .slider(min: 0, max: 1, step: 0.05), defaultValueText: "0.15"),
        TuningSpec(key: .vadWindowSize, kind: .picker(["512", "1024", "1536", "2048"]), defaultValueText: "512"),
        TuningSpec(key: .vadMaxSpeech, kind: .slider(min: 1, max: 20, step: 1), defaultValueText: "8.00"),
        TuningSpec(key: .speakerThreshold, kind: .slider(min: 0, max: 1, step: 0.02), defaultValueText: "0.62"),
        TuningSpec(key: .senseVoiceLanguage, kind: .picker(["auto", "zh", "en", "ja", "ko", "yue"]), defaultValueText: "auto"),
        TuningSpec(key: .senseVoiceITN, kind: .toggle, defaultValueText: "开"),
        TuningSpec(key: .senseVoiceThreads, kind: .stepper(min: 1, max: 4), defaultValueText: "2"),
        TuningSpec(key: .searchLimit, kind: .stepper(min: 1, max: 20), defaultValueText: "8")
    ]

    static let groups: [String] = [
        "Whisper 解码", "Silero VAD", "CAMPPlus 声纹", "SenseVoice", "EmbeddingGemma 搜索"
    ]
}

@MainActor
final class ModelTuningStore: ObservableObject {
    @Published var tuning: ModelTuning {
        didSet { persist() }
    }

    private let url: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.url = docs.appendingPathComponent("model_config.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ModelTuning.self, from: data) {
            self.tuning = decoded
        } else {
            self.tuning = .defaults
        }
    }

    /// 与默认值不同的参数个数。
    var deviationCount: Int { changedKeys.count }

    var changedKeys: [TuningKey] {
        var result: [TuningKey] = []
        for key in TuningKey.allCases {
            if !isAtDefault(key) { result.append(key) }
        }
        return result
    }

    /// Compare the ACTUAL typed value, never the formatted display string.
    /// String comparison used to report a permanent phantom deviation because
    /// `vadMaxSpeech` rendered as "8.00" while its default label was "8".
    func isAtDefault(_ key: TuningKey) -> Bool {
        let d = ModelTuning.defaults
        let t = tuning
        switch key {
        case .temperature: return t.temperature == d.temperature
        case .fallbackTemperature: return t.fallbackTemperature == d.fallbackTemperature
        case .temperatureFallbackCount: return t.temperatureFallbackCount == d.temperatureFallbackCount
        case .fallbackCount: return t.fallbackCount == d.fallbackCount
        case .baseWithoutTimestamps: return t.baseWithoutTimestamps == d.baseWithoutTimestamps
        case .baseRelaxQualityThresholds: return t.baseRelaxQualityThresholds == d.baseRelaxQualityThresholds
        case .skipSpecialTokens: return t.skipSpecialTokens == d.skipSpecialTokens
        case .vadThreshold: return t.vadThreshold == d.vadThreshold
        case .vadMinSilence: return t.vadMinSilence == d.vadMinSilence
        case .vadMinSpeech: return t.vadMinSpeech == d.vadMinSpeech
        case .vadWindowSize: return t.vadWindowSize == d.vadWindowSize
        case .vadMaxSpeech: return t.vadMaxSpeech == d.vadMaxSpeech
        case .speakerThreshold: return t.speakerThreshold == d.speakerThreshold
        case .senseVoiceLanguage: return t.senseVoiceLanguage == d.senseVoiceLanguage
        case .senseVoiceITN: return t.senseVoiceITN == d.senseVoiceITN
        case .senseVoiceThreads: return t.senseVoiceThreads == d.senseVoiceThreads
        case .searchLimit: return t.searchLimit == d.searchLimit
        }
    }

    func reset() {
        tuning = .defaults
    }

    func defaultValueText(for key: TuningKey) -> String {
        TuningCatalog.specs.first { $0.key == key }?.defaultValueText ?? "—"
    }

    func valueText(for key: TuningKey) -> String {
        let t = tuning
        switch key {
        case .temperature: return String(format: "%.2f", t.temperature)
        case .fallbackTemperature: return String(format: "%.2f", t.fallbackTemperature)
        case .temperatureFallbackCount: return "\(t.temperatureFallbackCount)"
        case .fallbackCount: return "\(t.fallbackCount)"
        case .baseWithoutTimestamps: return t.baseWithoutTimestamps ? "开" : "关"
        case .baseRelaxQualityThresholds: return t.baseRelaxQualityThresholds ? "开" : "关"
        case .skipSpecialTokens: return t.skipSpecialTokens ? "开" : "关"
        case .vadThreshold: return String(format: "%.2f", t.vadThreshold)
        case .vadMinSilence: return String(format: "%.2f", t.vadMinSilence)
        case .vadMinSpeech: return String(format: "%.2f", t.vadMinSpeech)
        case .vadWindowSize: return "\(t.vadWindowSize)"
        case .vadMaxSpeech: return String(format: "%.2f", t.vadMaxSpeech)
        case .speakerThreshold: return String(format: "%.2f", t.speakerThreshold)
        case .senseVoiceLanguage: return t.senseVoiceLanguage
        case .senseVoiceITN: return t.senseVoiceITN ? "开" : "关"
        case .senseVoiceThreads: return "\(t.senseVoiceThreads)"
        case .searchLimit: return "\(t.searchLimit)"
        }
    }

    /// 把当前值一次性同步给端侧 AI 引擎（标量赋值，无跨模块初始化器风险）。
    func applyToAudioIntelligence(_ ai: AudioIntelligence) {
        ai.vadThreshold = Float(tuning.vadThreshold)
        ai.vadMinSilenceDuration = Float(tuning.vadMinSilence)
        ai.vadMinSpeechDuration = Float(tuning.vadMinSpeech)
        ai.vadWindowSize = tuning.vadWindowSize
        ai.vadMaxSpeechDuration = Float(tuning.vadMaxSpeech)
        ai.speakerSimilarityThreshold = tuning.speakerThreshold
        ai.senseVoiceLanguageSetting = tuning.senseVoiceLanguage
        ai.senseVoiceUseITN = tuning.senseVoiceITN
        ai.senseVoiceThreadCount = tuning.senseVoiceThreads
        ai.searchResultLimit = tuning.searchLimit
    }

    /// 生成一份可写进调用日志的参数快照。
    func snapshot(operation: String) -> [String: String] {
        var params: [String: String] = [:]
        switch operation {
        case "transcribe", "retranscribe":
            for key in TuningKey.allCases where key.group == "Whisper 解码" {
                params[key.label] = valueText(for: key)
            }
        case "vad+speaker":
            for key in TuningKey.allCases where key.group == "Silero VAD" || key.group == "CAMPPlus 声纹" {
                params[key.label] = valueText(for: key)
            }
        case "senseVoice":
            for key in TuningKey.allCases where key.group == "SenseVoice" {
                params[key.label] = valueText(for: key)
            }
        case "embedding-index", "semantic-search":
            for key in TuningKey.allCases where key.group == "EmbeddingGemma 搜索" {
                params[key.label] = valueText(for: key)
            }
        default:
            for key in TuningKey.allCases { params[key.label] = valueText(for: key) }
        }
        return params
    }

    // MARK: Bindings（显式 switch，避免 Swift 6.1 的类型推断问题）

    func boolBinding(_ key: TuningKey) -> Binding<Bool> {
        Binding(get: {
            switch key {
            case .baseWithoutTimestamps: return self.tuning.baseWithoutTimestamps
            case .baseRelaxQualityThresholds: return self.tuning.baseRelaxQualityThresholds
            case .skipSpecialTokens: return self.tuning.skipSpecialTokens
            case .senseVoiceITN: return self.tuning.senseVoiceITN
            default: return false
            }
        }, set: { newValue in
            switch key {
            case .baseWithoutTimestamps: self.tuning.baseWithoutTimestamps = newValue
            case .baseRelaxQualityThresholds: self.tuning.baseRelaxQualityThresholds = newValue
            case .skipSpecialTokens: self.tuning.skipSpecialTokens = newValue
            case .senseVoiceITN: self.tuning.senseVoiceITN = newValue
            default: break
            }
        })
    }

    func doubleBinding(_ key: TuningKey) -> Binding<Double> {
        Binding(get: {
            switch key {
            case .temperature: return self.tuning.temperature
            case .fallbackTemperature: return self.tuning.fallbackTemperature
            case .vadThreshold: return self.tuning.vadThreshold
            case .vadMinSilence: return self.tuning.vadMinSilence
            case .vadMinSpeech: return self.tuning.vadMinSpeech
            case .vadMaxSpeech: return self.tuning.vadMaxSpeech
            case .speakerThreshold: return self.tuning.speakerThreshold
            default: return 0
            }
        }, set: { newValue in
            switch key {
            case .temperature: self.tuning.temperature = newValue
            case .fallbackTemperature: self.tuning.fallbackTemperature = newValue
            case .vadThreshold: self.tuning.vadThreshold = newValue
            case .vadMinSilence: self.tuning.vadMinSilence = newValue
            case .vadMinSpeech: self.tuning.vadMinSpeech = newValue
            case .vadMaxSpeech: self.tuning.vadMaxSpeech = newValue
            case .speakerThreshold: self.tuning.speakerThreshold = newValue
            default: break
            }
        })
    }

    func intBinding(_ key: TuningKey) -> Binding<Int> {
        Binding(get: {
            switch key {
            case .temperatureFallbackCount: return self.tuning.temperatureFallbackCount
            case .fallbackCount: return self.tuning.fallbackCount
            case .vadWindowSize: return self.tuning.vadWindowSize
            case .senseVoiceThreads: return self.tuning.senseVoiceThreads
            case .searchLimit: return self.tuning.searchLimit
            default: return 0
            }
        }, set: { newValue in
            switch key {
            case .temperatureFallbackCount: self.tuning.temperatureFallbackCount = newValue
            case .fallbackCount: self.tuning.fallbackCount = newValue
            case .vadWindowSize: self.tuning.vadWindowSize = newValue
            case .senseVoiceThreads: self.tuning.senseVoiceThreads = newValue
            case .searchLimit: self.tuning.searchLimit = newValue
            default: break
            }
        })
    }

    func stringBinding(_ key: TuningKey) -> Binding<String> {
        Binding(get: {
            switch key {
            case .senseVoiceLanguage: return self.tuning.senseVoiceLanguage
            default: return ""
            }
        }, set: { newValue in
            switch key {
            case .senseVoiceLanguage: self.tuning.senseVoiceLanguage = newValue
            default: break
            }
        })
    }

    private func persist() {
        guard let data = try? encoder.encode(tuning) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 结构化调用日志

enum CallStatus: String, Codable, Sendable {
    case ok
    case empty
    case failed

    var title: String {
        switch self {
        case .ok: return "成功"
        case .empty: return "空结果"
        case .failed: return "失败"
        }
    }
}

struct ModelCallRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let modelID: String
    let modelName: String
    let operation: String
    let modeRaw: String?
    let parameters: [String: String]
    let elapsed: TimeInterval
    let result: String
    let status: CallStatus
    let origin: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        modelID: String,
        modelName: String,
        operation: String,
        modeRaw: String? = nil,
        parameters: [String: String],
        elapsed: TimeInterval,
        result: String,
        status: CallStatus,
        origin: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelID = modelID
        self.modelName = modelName
        self.operation = operation
        self.modeRaw = modeRaw
        self.parameters = parameters
        self.elapsed = elapsed
        self.result = result
        self.status = status
        self.origin = origin
    }
}

@MainActor
final class ModelCallLog: ObservableObject {
    @Published private(set) var records: [ModelCallRecord] = []

    private let url: URL
    private let maxRecords = 400
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.url = docs.appendingPathComponent("model_calls.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode([ModelCallRecord].self, from: data) {
            self.records = decoded
        }
    }

    func record(
        modelID: String,
        operation: String,
        modeRaw: String? = nil,
        parameters: [String: String],
        elapsed: TimeInterval,
        result: String,
        status: CallStatus,
        origin: String
    ) {
        let name = ModelRegistry.descriptor(modelID)?.name ?? modelID
        let entry = ModelCallRecord(
            modelID: modelID,
            modelName: name,
            operation: operation,
            modeRaw: modeRaw,
            parameters: parameters,
            elapsed: elapsed,
            result: String(result.prefix(220)),
            status: status,
            origin: origin
        )
        records.append(entry)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    var successCount: Int {
        var n = 0
        for r in records where r.status == .ok { n += 1 }
        return n
    }

    var failedCount: Int {
        var n = 0
        for r in records where r.status == .failed { n += 1 }
        return n
    }

    var averageElapsed: TimeInterval {
        guard !records.isEmpty else { return 0 }
        var total: TimeInterval = 0
        for r in records { total += r.elapsed }
        return total / Double(records.count)
    }

    /// 把配置 + 日志导出成一份 JSON，供 CI artifact / 归档核对。
    func exportSnapshot(tuning: ModelTuning) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let target = docs.appendingPathComponent("model_management_export.json")
        let payload = ExportSnapshot(exportedAt: Date(), config: tuning, calls: records)
        guard let data = try? encoder.encode(payload) else { return nil }
        try? data.write(to: target, options: .atomic)
        return target
    }

    private func persist() {
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct ExportSnapshot: Codable {
    let exportedAt: Date
    let config: ModelTuning
    let calls: [ModelCallRecord]
}

// MARK: - 管理界面

struct ModelManagementView: View {
    @ObservedObject var tuningStore: ModelTuningStore
    @ObservedObject var callLog: ModelCallLog
    @Binding var selection: ManagementSection
    var onClose: () -> Void
    var onLog: (String) -> Void

    @State private var callFilter: CallFilter = .all

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分段", selection: $selection) {
                    ForEach(ManagementSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                ScrollView {
                    VStack(spacing: 14) {
                        switch selection {
                        case .overview: overviewSection
                        case .models: modelsSection
                        case .bindings: bindingsSection
                        case .tuning: tuningSection
                        case .calls: callsSection
                        }
                    }
                    .padding(14)
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("模式和模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onClose() }
                }
            }
        }
    }

    private var readyModelCount: Int {
        var n = 0
        for model in ModelRegistry.models where ModelRegistry.runtimeStatus(model).exists { n += 1 }
        return n
    }

    // MARK: 概览

    private var overviewSection: some View {
        VStack(spacing: 14) {
            MMCard(title: "部署总览", symbol: "shippingbox.fill") {
                MMKeyValue("已注册模型", "\(ModelRegistry.models.count) 个")
                MMKeyValue("运行时已打包", "\(readyModelCount) / \(ModelRegistry.models.count)")
                MMKeyValue("识别模式", "\(ModeBindingRegistry.bindings.count) 个")
                MMKeyValue("打包体积（标称）", String(format: "%.0f MB", Double(ModelRegistry.totalExpectedBytes) / 1_000_000))
                MMKeyValue("运行时零下载", "是 · 全部随 App 打包")
            }

            MMCard(title: "调用统计", symbol: "chart.bar.fill") {
                MMKeyValue("累计调用", "\(callLog.records.count) 次")
                MMKeyValue("成功 / 失败", "\(callLog.successCount) / \(callLog.failedCount)")
                MMKeyValue("平均耗时", String(format: "%.2f s", callLog.averageElapsed))
                MMKeyValue("最近一次", callLog.records.last.map { "\($0.modelName) · \($0.operation)" } ?? "尚无调用记录")
            }

            MMCard(title: "配置状态", symbol: "slider.horizontal.3") {
                MMKeyValue("可配置参数", "\(TuningCatalog.specs.count) 项")
                MMKeyValue("偏离默认", "\(tuningStore.deviationCount) 项")
                MMKeyValue("配置持久化", "Documents/model_config.json")
                MMKeyValue("调用日志持久化", "Documents/model_calls.json")
                Button {
                    if let url = callLog.exportSnapshot(tuning: tuningStore.tuning) {
                        onLog("MODEL MGMT export: \(url.lastPathComponent), calls=\(callLog.records.count)")
                    }
                } label: {
                    Label("导出配置与日志", systemImage: "square.and.arrow.up")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }

            MMCard(title: "一次录音的完整链路", symbol: "arrow.triangle.branch") {
                ForEach(ModeBindingRegistry.pipelineStages.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.blue))
                        Text(ModeBindingRegistry.pipelineStages[index]).font(.caption)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: 模型清单

    private var modelsSection: some View {
        VStack(spacing: 12) {
            ForEach(ModelRegistry.models) { model in
                ModelDetailCard(model: model, status: ModelRegistry.runtimeStatus(model))
            }
        }
    }

    // MARK: 模式映射

    private var bindingsSection: some View {
        VStack(spacing: 12) {
            ForEach(ModeBindingRegistry.bindings) { binding in
                ModeBindingCard(binding: binding)
            }

            MMCard(title: "语言目录差异", symbol: "globe") {
                Text("Whisper 的 language 参数是「把音频当作何种语言解码」，不是翻译。")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MMKeyValue("普通模式", "99 语种 · 无粤语 yue · 自动检测 + 99 = 100 项")
                MMKeyValue("精准模式", "100 语种 · 含粤语 yue · 自动检测 + 100 = 101 项")
                Text("切换模式时 selectedTarget 会回落到该模式默认项；选错语言可在条目的感叹号备注里重新转写重选。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 参数配置

    private var tuningSection: some View {
        VStack(spacing: 12) {
            MMCard(title: "参数生效说明", symbol: "info.circle.fill") {
                Text("此页参数会真实作用于下一次调用：Whisper 解码参数传入 DecodingOptions；VAD / 声纹 / SenseVoice / 搜索参数写入端侧引擎。每次调用的参数快照会记入「日志」分段。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("偏离默认 \(tuningStore.deviationCount) 项")
                        .font(.caption.bold())
                        .foregroundColor(tuningStore.deviationCount == 0 ? .green : .orange)
                    Spacer()
                    Button("恢复默认") { tuningStore.reset() }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                }
            }

            ForEach(TuningCatalog.groups, id: \.self) { group in
                TuningGroupCard(group: group, store: tuningStore)
            }
        }
    }

    // MARK: 调用日志

    private var callsSection: some View {
        VStack(spacing: 12) {
            MMCard(title: "调用日志", symbol: "list.bullet.rectangle") {
                Picker("筛选", selection: $callFilter) {
                    ForEach(CallFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                MMKeyValue("总记录", "\(callLog.records.count) 条")
                MMKeyValue("当前筛选", "\(filteredCalls.count) 条")
                HStack(spacing: 10) {
                    Button(role: .destructive) { callLog.clear() } label: {
                        Label("清空", systemImage: "trash").font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    Button {
                        if let url = callLog.exportSnapshot(tuning: tuningStore.tuning) {
                            onLog("MODEL MGMT export: \(url.lastPathComponent)")
                        }
                    } label: {
                        Label("导出 JSON", systemImage: "square.and.arrow.up").font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }

            if filteredCalls.isEmpty {
                MMCard(title: "暂无记录", symbol: "tray") {
                    Text("完成一次转写或语义搜索后，这里会显示模型、模式、参数快照、耗时与结果。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(filteredCalls) { record in
                    CallRecordCard(record: record)
                }
            }
        }
    }

    private var filteredCalls: [ModelCallRecord] {
        let list: [ModelCallRecord]
        switch callFilter {
        case .all: list = callLog.records
        case .ok: list = callLog.records.filter { $0.status == .ok }
        case .issues: list = callLog.records.filter { $0.status != .ok }
        }
        return list.reversed()
    }
}

enum CallFilter: String, CaseIterable, Identifiable {
    case all
    case ok
    case issues

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .ok: return "成功"
        case .issues: return "异常"
        }
    }
}

// MARK: - 复用视图组件

struct MMCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct MMKeyValue: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

struct ModelDetailCard: View {
    let model: ModelDescriptor
    let status: ModelRuntimeStatus

    var body: some View {
        MMCard(title: model.name, symbol: roleSymbol) {
            MMKeyValue("角色", model.role.title)
            MMKeyValue("引擎", model.engine)
            MMKeyValue("格式 / 版本", "\(model.format) · \(model.version)")
            MMKeyValue("规格", model.dimensionNote)
            MMKeyValue("使用模式", model.usedIn)
            Text(model.purpose)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                Label(status.exists ? "已打包" : "缺失", systemImage: status.exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundColor(status.exists ? .green : .red)
                Spacer()
                Text(status.exists ? runtimeSizeText : "未在 bundle 中找到")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            MMKeyValue("标称体积", model.expectedSizeText)
            MMKeyValue("bundle 路径", "…/\(model.bundlePath)")
            Text("源码：" + model.sourceTrace)
                .font(.caption2)
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runtimeSizeText: String {
        if model.isDirectory {
            return "\(status.fileCount) 个文件 · \(formatBytes(status.bytes))"
        }
        return formatBytes(status.bytes)
    }

    private var roleSymbol: String {
        switch model.role {
        case .primaryASR: return "waveform.circle.fill"
        case .secondaryASR: return "text.bubble.fill"
        case .vad: return "chart.bar.fill"
        case .speaker: return "person.wave.2.fill"
        case .embedding: return "magnifyingglass.circle.fill"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }
}

struct ModeBindingCard: View {
    let binding: ModeBinding

    var body: some View {
        MMCard(title: binding.modeTitle, symbol: binding.modeRaw == "standard" ? "bolt.fill" : "sparkles") {
            MMKeyValue("主 ASR", ModelRegistry.descriptor(binding.primaryModelID)?.name ?? binding.primaryModelID)
            MMKeyValue("模型目录", "Models/\(ModelRegistry.descriptor(binding.primaryModelID)?.bundlePath ?? "—")")
            MMKeyValue("识别语言", "\(binding.languageCount) 种")
            Text(binding.languageNote)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            Text("解码策略").font(.caption.bold())
            Text(binding.decodingNote)
                .font(.caption2)
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            Text("辅助模型链（两种模式共用）").font(.caption.bold())
            ForEach(binding.pipelineIDs.indices, id: \.self) { index in
                PipelineRow(index: index, modelID: binding.pipelineIDs[index])
            }

            Divider()
            Text("源码：" + binding.sourceTrace)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PipelineRow: View {
    let index: Int
    let modelID: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            Text(ModelRegistry.descriptor(modelID)?.name ?? modelID).font(.caption)
            Spacer()
            Text(ModelRegistry.descriptor(modelID)?.role.title ?? "")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct TuningGroupCard: View {
    let group: String
    @ObservedObject var store: ModelTuningStore

    private var specs: [TuningSpec] {
        TuningCatalog.specs.filter { $0.key.group == group }
    }

    var body: some View {
        MMCard(title: group, symbol: "slider.horizontal.3") {
            ForEach(specs.indices, id: \.self) { index in
                ParamEditorRow(spec: specs[index], store: store)
                if index < specs.count - 1 { Divider() }
            }
        }
    }
}

struct ParamEditorRow: View {
    let spec: TuningSpec
    @ObservedObject var store: ModelTuningStore

    private var isChanged: Bool {
        !store.isAtDefault(spec.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(spec.key.label).font(.caption.bold())
                Spacer()
                Text(isChanged ? "已修改" : "默认")
                    .font(.caption2.bold())
                    .foregroundColor(isChanged ? .orange : .green)
            }

            ParamControl(spec: spec, store: store)

            Text(spec.key.hint)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("源码：" + spec.key.sourceTrace)
                .font(.caption2)
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

/// 控件独立成 View，避免 ViewBuilder 闭包里出现局部 let 声明
/// （Swift 6.1 / Xcode 16.4 严格模式下的推断坑）。
struct ParamControl: View {
    let spec: TuningSpec
    @ObservedObject var store: ModelTuningStore

    var body: some View {
        VStack {
            switch spec.kind {
            case .toggle:
                Toggle(isOn: store.boolBinding(spec.key)) {
                    Text("当前 \(store.valueText(for: spec.key)) · 默认 \(spec.defaultValueText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            case .slider(let min, let max, let step):
                HStack {
                    Slider(value: store.doubleBinding(spec.key), in: min...max, step: step)
                    Text(store.valueText(for: spec.key))
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
            case .stepper(let min, let max):
                HStack {
                    Stepper(value: store.intBinding(spec.key), in: min...max) {
                        Text("当前 \(store.valueText(for: spec.key))")
                            .font(.caption2.monospacedDigit())
                    }
                    .font(.caption)
                    Spacer()
                }
            case .picker(let options):
                Picker(spec.key.label, selection: pickerBinding(options: options)) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .font(.caption)
            }
        }
    }

    /// picker 统一走字符串绑定；数字型（vadWindowSize）双向转换。
    private func pickerBinding(options: [String]) -> Binding<String> {
        if spec.key == .vadWindowSize {
            return Binding(
                get: { "\(store.tuning.vadWindowSize)" },
                set: { newValue in
                    if let n = Int(newValue) { store.tuning.vadWindowSize = n }
                }
            )
        }
        return store.stringBinding(spec.key)
    }
}

struct CallRecordCard: View {
    let record: ModelCallRecord

    var body: some View {
        MMCard(title: record.modelName, symbol: statusSymbol) {
            HStack {
                Text(record.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Text(record.status.title)
                    .font(.caption2.bold())
                    .foregroundColor(statusColor)
            }
            MMKeyValue("操作", record.operation + (record.modeRaw.map { " · \($0)" } ?? ""))
            MMKeyValue("耗时", String(format: "%.2f s", record.elapsed))
            MMKeyValue("来源", record.origin)
            MMKeyValue("结果", record.result.isEmpty ? "（空）" : record.result)
            if !record.parameters.isEmpty {
                Divider()
                Text("调用参数快照").font(.caption.bold())
                ForEach(record.parameters.keys.sorted(), id: \.self) { key in
                    MMKeyValue(key, record.parameters[key] ?? "—")
                }
            }
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .ok: return .green
        case .empty: return .orange
        case .failed: return .red
        }
    }

    private var statusSymbol: String {
        switch record.status {
        case .ok: return "checkmark.circle.fill"
        case .empty: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}
