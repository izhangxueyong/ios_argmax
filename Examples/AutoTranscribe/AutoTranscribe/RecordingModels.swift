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

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        source: RecordingSource,
        duration: TimeInterval,
        waveform: [Double],
        usesBundledSample: Bool = false,
        storedFileName: String? = nil,
        transcript: String? = nil
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
