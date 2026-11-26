//  RecordingModels.swift
//  Recording list data, conversation sessions, persistence and waveform extraction.
//
//  Session model:
//   - Every "press and hold to talk" clip belongs to the CURRENT session.
//   - A session stays open (not archived) until the user taps the checkmark
//     button next to the round record buttons.
//   - Tapping the checkmark archives that session and opens a fresh one.
//   - Only archived sessions appear in the "archived recording list", and a
//     session detail shows ALL of its hold-to-talk clips in one view.

import AVFoundation
import AutoTranscribeAI
import Foundation
import SwiftUI

// MARK: - Per-model language catalogs
//
// Both bundled models are WhisperKit checkpoints, but they do NOT share the
// same tokenizer / language set:
//   * openai_whisper-base (ordinary): the original 99 Whisper languages.
//     Cantonese `yue` was introduced only in large-v3, so base cannot emit it.
//   * openai_whisper-large-v3-v20240930_turbo (precise): 100 language codes
//     (99 + yue) from WhisperKit Constants.languages.
//
// IMPORTANT (Whisper semantics): picking a language does NOT translate the
// audio. It tells Whisper "treat this recording as spoken in language X" and
// the transcript is emitted in that same language. Picking the wrong language
// produces a bad transcript; the fix is to retranscribe the item and pick a
// different language. That is exactly what the per-item retranscribe sheet is
// for. There is deliberately no "translate to English" option in this app.
// A retranscription picker must swap the whole list when the mode changes.

struct TranscriptionTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    /// nil = let WhisperKit detect the spoken language; otherwise this code is
    /// passed to DecodingOptions(language:) as the language to decode in.
    var languageCode: String?

    var detail: String {
        if languageCode == nil { return "不指定 · 由模型自动检测音频语言" }
        return "把这段录音当作该语言转写 · 输出同语种文本（非翻译）"
    }
}

struct TranscriptionMeta: Codable, Equatable, Sendable {
    var modelName: String
    var modeTitle: String
    var modeRaw: String
    var elapsed: TimeInterval
    /// Language WhisperKit detected from the audio (factual measurement).
    var sourceLanguage: String
    /// Language the user asked the decoder to use (or "自动检测").
    var targetLanguage: String
    var taskTitle: String
    var retranscribeCount: Int
    var finishedAt: Date

    /// There is no "source -> target" translation: both fields describe ONE
    /// transcription. Show them side by side so a wrong pick is obvious.
    var direction: String { "检测 \(sourceLanguage) · 指定 \(targetLanguage)" }
    var languageAgreement: String {
        if targetLanguage == "自动检测" {
            return "未指定 · 由模型自动判定（实测 \(sourceLanguage)）"
        }
        return sourceLanguage == targetLanguage
            ? "一致 · 按该语言解码，输出同语种文本"
            : "不一致 · 可能选错语言，可重新转写重选后重跑"
    }
    var elapsedTitle: String { String(format: "%.1f 秒", elapsed) }
}

enum LanguageCatalog {
    /// Unique language codes from WhisperKit `Constants.languages`
    /// (Sources/WhisperKit/Core/Models.swift). large-v3 added Cantonese `yue`.
    static let whisperCodes: [String] = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh"
    ]

    static let chineseNames: [String: String] = [
        "af": "南非荷兰语", "am": "阿姆哈拉语", "ar": "阿拉伯语", "as": "阿萨姆语",
        "az": "阿塞拜疆语", "ba": "巴什基尔语", "be": "白俄罗斯语", "bg": "保加利亚语",
        "bn": "孟加拉语", "bo": "藏语", "br": "布列塔尼语", "bs": "波斯尼亚语",
        "ca": "加泰罗尼亚语", "cs": "捷克语", "cy": "威尔士语", "da": "丹麦语",
        "de": "德语", "el": "希腊语", "en": "英语", "es": "西班牙语",
        "et": "爱沙尼亚语", "eu": "巴斯克语", "fa": "波斯语", "fi": "芬兰语",
        "fo": "法罗语", "fr": "法语", "gl": "加利西亚语", "gu": "古吉拉特语",
        "ha": "豪萨语", "haw": "夏威夷语", "he": "希伯来语", "hi": "印地语",
        "hr": "克罗地亚语", "ht": "海地克里奥尔语", "hu": "匈牙利语", "hy": "亚美尼亚语",
        "id": "印尼语", "is": "冰岛语", "it": "意大利语", "ja": "日语",
        "jw": "爪哇语", "ka": "格鲁吉亚语", "kk": "哈萨克语", "km": "高棉语",
        "kn": "卡纳达语", "ko": "韩语", "la": "拉丁语", "lb": "卢森堡语",
        "ln": "林加拉语", "lo": "老挝语", "lt": "立陶宛语", "lv": "拉脱维亚语",
        "mg": "马达加斯加语", "mi": "毛利语", "mk": "马其顿语", "ml": "马拉雅拉姆语",
        "mn": "蒙古语", "mr": "马拉地语", "ms": "马来语", "mt": "马耳他语",
        "my": "缅甸语", "ne": "尼泊尔语", "nl": "荷兰语", "nn": "新挪威语",
        "no": "挪威语", "oc": "奥克语", "pa": "旁遮普语", "pl": "波兰语",
        "ps": "普什图语", "pt": "葡萄牙语", "ro": "罗马尼亚语", "ru": "俄语",
        "sa": "梵语", "sd": "信德语", "si": "僧伽罗语", "sk": "斯洛伐克语",
        "sl": "斯洛文尼亚语", "sn": "绍纳语", "so": "索马里语", "sq": "阿尔巴尼亚语",
        "sr": "塞尔维亚语", "su": "巽他语", "sv": "瑞典语", "sw": "斯瓦希里语",
        "ta": "泰米尔语", "te": "泰卢固语", "tg": "塔吉克语", "th": "泰语",
        "tk": "土库曼语", "tl": "他加禄语", "tr": "土耳其语", "tt": "鞑靼语",
        "uk": "乌克兰语", "ur": "乌尔都语", "uz": "乌兹别克语", "vi": "越南语",
        "yi": "意第绪语", "yo": "约鲁巴语", "yue": "粤语", "zh": "中文"
    ]

    static func displayName(for code: String?) -> String {
        guard let code else { return "自动检测" }
        let name = chineseNames[code] ?? code.uppercased()
        return "\(name) (\(code))"
    }

    /// Compact label used on the two hold-to-talk buttons.
    static func shortName(for code: String) -> String {
        chineseNames[code] ?? code.uppercased()
    }

    /// A saved clip is never "recording", so it must never be red. The tint
    /// also distinguishes the two hold-to-talk speakers in the archive.
    static func tint(for code: String?) -> Color {
        guard let code else { return .blue }
        if code == "zh" || code == "yue" { return .blue }
        if code == "en" { return .purple }
        return .teal
    }

    /// Whisper Base uses the original 99-language tokenizer: Cantonese `yue`
    /// was only added by large-v3, so it must not be offered for base.
    static let baseCodes: [String] = whisperCodes.filter { $0 != "yue" }

    /// large-v3-turbo ships every code in WhisperKit Constants.languages.
    static let turboCodes: [String] = whisperCodes

    static func makeTargets(codes: [String]) -> [TranscriptionTarget] {
        var list: [TranscriptionTarget] = [
            TranscriptionTarget(id: "auto", title: "自动检测", languageCode: nil)
        ]
        for code in codes {
            list.append(TranscriptionTarget(
                id: code,
                title: displayName(for: code),
                languageCode: code
            ))
        }
        return list
    }

    /// Ordinary mode: 99 languages (no yue) + auto = 100 options.
    static let baseTargets: [TranscriptionTarget] = makeTargets(codes: baseCodes)

    /// Precise mode: 100 languages (incl. yue) + auto = 101 options.
    static let turboTargets: [TranscriptionTarget] = makeTargets(codes: turboCodes)

    static func targets(for mode: TranscriptionMode) -> [TranscriptionTarget] {
        switch mode {
        case .standard: return baseTargets
        case .precise: return turboTargets
        }
    }

    static func countLabel(for mode: TranscriptionMode) -> String {
        switch mode {
        case .standard:
            return "Whisper Base · \(baseCodes.count) 种可选识别语言（不含粤语）"
        case .precise:
            return "Whisper Turbo · \(turboCodes.count) 种可选识别语言（含粤语）"
        }
    }

    static func defaultTarget(for mode: TranscriptionMode) -> TranscriptionTarget {
        targets(for: mode)[0]
    }

    /// Fall back to a legal target whenever the mode changes: base has no
    /// `yue` option, so a precise-mode Cantonese selection must be replaced.
    static func validated(_ target: TranscriptionTarget, for mode: TranscriptionMode) -> TranscriptionTarget {
        targets(for: mode).first { $0.id == target.id } ?? defaultTarget(for: mode)
    }

    // MARK: 按「实际主模型」判断，而不是按模式
    // 自定义模型链可以把普通模式换成 Turbo，或把精准模式换成 Base。
    // 语言目录、默认项和非法项回落都必须跟着真实模型走，否则会丢粤语
    // 或把 yue 传给不支持它的 base tokenizer。

    /// SenseVoiceSmall int8 的显式语言参数是 auto / zh / en / ja / ko / yue，
    /// 与 Whisper tokenizer 的语言表不同，不能复用 base / turbo 的目录。
    static let senseVoiceCodes: [String] = ["zh", "en", "ja", "ko", "yue"]
    static let senseVoiceTargets: [TranscriptionTarget] = makeTargets(codes: senseVoiceCodes)

    static func targets(forModelID id: String) -> [TranscriptionTarget] {
        switch id {
        case "whisper-turbo": return turboTargets
        case "sense-voice": return senseVoiceTargets
        default: return baseTargets
        }
    }

    static func countLabel(forModelID id: String) -> String {
        switch id {
        case "whisper-turbo":
            return "Whisper Turbo · \(turboCodes.count) 种可选识别语言（含粤语）"
        case "sense-voice":
            return "SenseVoiceSmall int8 · 自动检测 + 中 / 英 / 日 / 韩 / 粤"
        default:
            return "Whisper Base · \(baseCodes.count) 种可选识别语言（不含粤语）"
        }
    }

    static func defaultTarget(forModelID id: String) -> TranscriptionTarget {
        targets(forModelID: id)[0]
    }

    static func validated(_ target: TranscriptionTarget, forModelID id: String) -> TranscriptionTarget {
        let list = targets(forModelID: id)
        return list.first { $0.id == target.id } ?? list[0]
    }
}

enum RecordingSource: String, Codable, CaseIterable, Sendable {
    case long
    case pushToTalk
    case tap

    var sectionTitle: String {
        switch self {
        case .long: return "长录音"
        case .pushToTalk: return "按住说话"
        case .tap: return "单击录音"
        }
    }

    var badge: String {
        switch self {
        case .long: return "长"
        case .pushToTalk: return "按住"
        case .tap: return "单击"
        }
    }
}

struct RecordingItem: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var fileName: String
    var source: RecordingSource
    var createdAt: Date
    var duration: TimeInterval
    var waveform: [Double]
    var usesBundledSample: Bool
    var storedFileName: String?
    var transcript: String?
    /// For a hold-to-talk clip: which of the two language buttons produced it.
    /// The stored code is used as DecodingOptions(language:) when transcribing,
    /// so two people speaking different languages share one session correctly.
    /// Optional so recordings.json written by older builds still decodes.
    var holdLanguageCode: String?
    /// Model, elapsed time and language facts of the LAST transcription.
    /// Optional so recordings.json written by older builds still decodes.
    var transcription: TranscriptionMeta?
    /// Silero VAD speech ranges + CAMPPlus "is it me?" verdict per range.
    var voiceTimeline: AudioAnalysis?
    /// SenseVoiceSmall int8 on-device recognition of the same clip.
    var senseVoiceText: String?
    var senseVoiceLanguage: String?
    /// EmbeddingGemma sentence vector used by the archive semantic search.
    var searchVector: [Float]?

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        source: RecordingSource,
        duration: TimeInterval,
        waveform: [Double],
        usesBundledSample: Bool = false,
        storedFileName: String? = nil,
        transcript: String? = nil,
        holdLanguageCode: String? = nil,
        transcription: TranscriptionMeta? = nil,
        voiceTimeline: AudioAnalysis? = nil,
        senseVoiceText: String? = nil,
        senseVoiceLanguage: String? = nil,
        searchVector: [Float]? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.source = source
        self.createdAt = Date()
        self.duration = duration
        self.waveform = waveform
        self.usesBundledSample = usesBundledSample
        self.storedFileName = storedFileName
        self.transcript = transcript
        self.holdLanguageCode = holdLanguageCode
        self.transcription = transcription
        self.voiceTimeline = voiceTimeline
        self.senseVoiceText = senseVoiceText
        self.senseVoiceLanguage = senseVoiceLanguage
        self.searchVector = searchVector
    }

    /// Short model badge shown on every archived row.
    var modelBadge: String {
        guard let meta = transcription else { return "未转写" }
        return meta.modelName
    }
}

struct RecordingSession: Codable, Identifiable, Sendable {
    let id: UUID
    var index: Int
    var createdAt: Date
    var archivedAt: Date?
    var isArchived: Bool
    var itemIDs: [UUID]

    init(
        id: UUID = UUID(),
        index: Int,
        createdAt: Date = Date(),
        archivedAt: Date? = nil,
        isArchived: Bool = false,
        itemIDs: [UUID] = []
    ) {
        self.id = id
        self.index = index
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.isArchived = isArchived
        self.itemIDs = itemIDs
    }

    var title: String {
        "会话 \(index)"
    }
}

enum WaveformExtractor {
    static func samples(from url: URL, bars: Int = 48) -> [Double] {
        guard let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: file.processingFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0] else {
            return fallback(bars: bars)
        }

        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return fallback(bars: bars) }
        let step = max(1, frames / bars)
        var values = [Double](repeating: 0, count: bars)

        for bar in 0..<bars {
            let start = bar * step
            guard start < frames else { break }
            let end = Swift.min(start + step, frames)
            var sum: Float = 0
            for i in start..<end {
                let sample: Float = channel[i]
                sum += sample * sample
            }
            let count: Float = Float(end - start)
            let mean: Float = sum / count
            values[bar] = Double(sqrt(mean))
        }

        let peak: Double = values.max() ?? 0
        guard peak > 0 else { return fallback(bars: bars) }
        var normalized = [Double]()
        normalized.reserveCapacity(bars)
        for value in values {
            let ratio: Double = value / peak
            let lower: Double = Swift.max(0.08, ratio)
            let clamped: Double = Swift.min(1.0, lower)
            normalized.append(clamped)
        }
        return normalized
    }

    static func fallback(bars: Int = 48) -> [Double] {
        var values = [Double]()
        values.reserveCapacity(bars)
        for i in 0..<bars {
            let phase: Double = Double(i)
            let wave: Double = sin(phase * 0.47) * cos(phase * 0.19)
            let amplitude: Double = abs(wave)
            let value: Double = 0.18 + 0.62 * amplitude
            values.append(value)
        }
        return values
    }

    /// Concatenate several clip waveforms into one long thumbnail waveform.
    static func merged(_ clips: [RecordingItem], bars: Int = 48) -> [Double] {
        guard !clips.isEmpty else { return fallback(bars: bars) }
        let perClip = Swift.max(6, bars / clips.count)
        var combined: [Double] = []
        combined.reserveCapacity(bars)
        for clip in clips {
            let source = clip.waveform
            let count = Swift.min(perClip, source.count)
            for i in 0..<count {
                combined.append(source[i])
            }
        }
        guard combined.count >= bars else {
            return combined + [Double](repeating: 0.12, count: bars - combined.count)
        }
        let step = Swift.max(1, combined.count / bars)
        var result: [Double] = []
        result.reserveCapacity(bars)
        for i in 0..<bars {
            let position = Swift.min(combined.count - 1, i * step)
            result.append(combined[position])
        }
        return result
    }
}

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var items: [RecordingItem] = []
    @Published private(set) var sessions: [RecordingSession] = []

    private let metadataURL: URL
    private let sessionsURL: URL
    private let documentsURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documentsURL = docs
        self.metadataURL = docs.appendingPathComponent("recordings.json")
        self.sessionsURL = docs.appendingPathComponent("sessions.json")
        load()
        if sessions.isEmpty {
            sessions = [RecordingSession(index: 1)]
            saveSessions()
        }
        if items.isEmpty { seed() }
    }

    var documentsDirectory: URL { documentsURL }

    // MARK: - Sessions

    /// The one open (unarchived) session. All new hold-to-talk clips go here.
    var currentSession: RecordingSession? {
        sessions.first { !$0.isArchived }
    }

    var archivedSessions: [RecordingSession] {
        let list = sessions.filter { $0.isArchived && !$0.itemIDs.isEmpty }
        return list.sorted { $0.index > $1.index }
    }

    /// All hold-to-talk clips of a session, in the order they were spoken.
    func items(in session: RecordingSession) -> [RecordingItem] {
        var result: [RecordingItem] = []
        for id in session.itemIDs {
            if let match = items.first(where: { $0.id == id }) {
                result.append(match)
            }
        }
        return result
    }

    /// Archive the open session and immediately open a fresh one.
    /// Returns the archived session, or nil when there is nothing to archive.
    @discardableResult
    func archiveCurrentSession() -> RecordingSession? {
        guard let index = sessions.firstIndex(where: { !$0.isArchived }) else { return nil }
        let open = sessions[index]
        guard !open.itemIDs.isEmpty else { return nil }

        sessions[index].isArchived = true
        sessions[index].archivedAt = Date()
        let archived = sessions[index]

        var highest = 0
        for session in sessions {
            if session.index > highest { highest = session.index }
        }
        let fresh = RecordingSession(index: highest + 1)
        sessions.append(fresh)
        saveSessions()
        return archived
    }

    // MARK: - Items

    func items(for source: RecordingSource) -> [RecordingItem] {
        items.filter { $0.source == source }.sorted { $0.createdAt > $1.createdAt }
    }

    func audioURL(for item: RecordingItem) -> URL? {
        if item.usesBundledSample {
            return BundledResources.url(forResource: "recording", withExtension: "wav")
        }
        guard let name = item.storedFileName else { return nil }
        return documentsURL.appendingPathComponent(name)
    }

    @discardableResult
    func add(
        name: String,
        fileName: String,
        source: RecordingSource,
        duration: TimeInterval,
        waveform: [Double],
        audioData: Data? = nil,
        usesBundledSample: Bool = false,
        holdLanguageCode: String? = nil
    ) -> RecordingItem {
        var storedName: String?
        if let audioData {
            storedName = "recording_\(UUID().uuidString.prefix(8)).wav"
            try? audioData.write(to: documentsURL.appendingPathComponent(storedName!), options: .atomic)
        }
        let item = RecordingItem(
            name: name,
            fileName: fileName,
            source: source,
            duration: duration,
            waveform: waveform,
            usesBundledSample: usesBundledSample,
            storedFileName: storedName,
            holdLanguageCode: holdLanguageCode
        )
        items.insert(item, at: 0)

        // A hold-to-talk clip always belongs to the current open session.
        if source == .pushToTalk {
            if let openIndex = sessions.firstIndex(where: { !$0.isArchived }) {
                sessions[openIndex].itemIDs.append(item.id)
                saveSessions()
            }
        }
        save()
        return item
    }

    func updateTranscript(for id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].transcript = text
        save()
    }

    /// Persist the transcript together with its model / timing / language metadata.
    func updateTranscription(for id: UUID, text: String, meta: TranscriptionMeta) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].transcript = text
        items[index].transcription = meta
        save()
    }

    /// Persist the VAD timeline and CAMPPlus speaker verdict for an item.
    func updateAnalysis(for id: UUID, analysis: AudioAnalysis) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].voiceTimeline = analysis
        save()
    }

    func updateSenseVoice(for id: UUID, text: String, language: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].senseVoiceText = text
        items[index].senseVoiceLanguage = language
        save()
    }

    func updateSearchVector(for id: UUID, vector: [Float]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].searchVector = vector
        save()
    }

    func item(with id: UUID) -> RecordingItem? {
        items.first { $0.id == id }
    }

    func bundledSample() -> RecordingItem? {
        items.first { $0.usesBundledSample }
    }

    // MARK: - Persistence

    private func seed() {
        if let url = BundledResources.url(forResource: "recording", withExtension: "wav") {
            let item = RecordingItem(
                name: "JFK 演讲样本",
                fileName: "recording.wav",
                source: .long,
                duration: 11,
                waveform: WaveformExtractor.samples(from: url),
                usesBundledSample: true
            )
            items = [item]
            save()
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([RecordingItem].self, from: data) {
            items = decoded
        }
        if let data = try? Data(contentsOf: sessionsURL),
           let decoded = try? JSONDecoder().decode([RecordingSession].self, from: data) {
            sessions = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func saveSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }
}
