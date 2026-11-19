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
import Foundation
import SwiftUI

// MARK: - Per-model language catalogs
//
// The two bundled ASR models do NOT support the same set of target languages:
//   * SenseVoice-small (FluidAudio): auto + zh / en / yue / ja / ko, 6 options.
//     Its `language` argument is the FunASR lid_dict embed index
//     (auto=0, zh=1, en=2, yue=3, ja=4, ko=5).
//   * Whisper large-v3-turbo (WhisperKit): every code in
//     WhisperKit Constants.languages (100 codes, incl. yue) plus the
//     built-in .translate task, which always emits English.
// A retranscription picker must swap the whole list when the mode changes.

struct TranscriptionTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var languageCode: String?
    var isTranslation: Bool
    var senseVoiceIndex: Int32?

    var detail: String {
        if isTranslation { return "语音翻译任务 · 输出英文" }
        if languageCode == nil { return "自动检测源语言 · 按原语种输出" }
        return "指定识别语言 · 按该语种输出"
    }
}

struct TranscriptionMeta: Codable, Equatable, Sendable {
    var modelName: String
    var modeTitle: String
    var modeRaw: String
    var elapsed: TimeInterval
    var sourceLanguage: String
    var targetLanguage: String
    var taskTitle: String
    var retranscribeCount: Int
    var finishedAt: Date

    var direction: String { "\(sourceLanguage) → \(targetLanguage)" }
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

    /// SenseVoice's language list is deliberately short: the model only has
    /// five explicit language query embeddings besides auto detection.
    static let senseVoiceTargets: [TranscriptionTarget] = [
        TranscriptionTarget(id: "auto", title: "自动检测", languageCode: nil, isTranslation: false, senseVoiceIndex: 0),
        TranscriptionTarget(id: "zh", title: "中文 (zh)", languageCode: "zh", isTranslation: false, senseVoiceIndex: 1),
        TranscriptionTarget(id: "en", title: "英语 (en)", languageCode: "en", isTranslation: false, senseVoiceIndex: 2),
        TranscriptionTarget(id: "yue", title: "粤语 (yue)", languageCode: "yue", isTranslation: false, senseVoiceIndex: 3),
        TranscriptionTarget(id: "ja", title: "日语 (ja)", languageCode: "ja", isTranslation: false, senseVoiceIndex: 4),
        TranscriptionTarget(id: "ko", title: "韩语 (ko)", languageCode: "ko", isTranslation: false, senseVoiceIndex: 5)
    ]

    static let whisperTargets: [TranscriptionTarget] = {
        var list: [TranscriptionTarget] = [
            TranscriptionTarget(id: "auto", title: "自动检测", languageCode: nil, isTranslation: false, senseVoiceIndex: nil)
        ]
        for code in whisperCodes {
            list.append(TranscriptionTarget(
                id: code,
                title: displayName(for: code),
                languageCode: code,
                isTranslation: false,
                senseVoiceIndex: nil
            ))
        }
        // Whisper's .translate task is the only true cross-language option.
        list.append(TranscriptionTarget(
            id: "translate-en",
            title: "翻译为英文 (en)",
            languageCode: "en",
            isTranslation: true,
            senseVoiceIndex: nil
        ))
        return list
    }()

    static func targets(for mode: TranscriptionMode) -> [TranscriptionTarget] {
        switch mode {
        case .standard: return senseVoiceTargets
        case .precise: return whisperTargets
        }
    }

    static func countLabel(for mode: TranscriptionMode) -> String {
        switch mode {
        case .standard:
            return "SenseVoice-small · 支持 \(senseVoiceTargets.count) 种语言（含自动检测）"
        case .precise:
            return "Whisper Turbo · 支持 \(whisperCodes.count) 种语言 + 翻译为英文"
        }
    }

    static func defaultTarget(for mode: TranscriptionMode) -> TranscriptionTarget {
        targets(for: mode)[0]
    }

    /// Fall back to a legal target whenever the mode changes, because the two
    /// catalogs do not share the same option ids.
    static func validated(_ target: TranscriptionTarget, for mode: TranscriptionMode) -> TranscriptionTarget {
        targets(for: mode).first { $0.id == target.id } ?? defaultTarget(for: mode)
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
    /// Model, elapsed time and language direction of the LAST transcription.
    /// Optional so recordings.json written by older builds still decodes.
    var transcription: TranscriptionMeta?

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
        transcription: TranscriptionMeta? = nil
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
        self.transcription = transcription
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
            return Bundle.main.url(forResource: "recording", withExtension: "wav")
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
        usesBundledSample: Bool = false
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
            storedFileName: storedName
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

    func item(with id: UUID) -> RecordingItem? {
        items.first { $0.id == id }
    }

    func bundledSample() -> RecordingItem? {
        items.first { $0.usesBundledSample }
    }

    // MARK: - Persistence

    private func seed() {
        if let url = Bundle.main.url(forResource: "recording", withExtension: "wav") {
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
