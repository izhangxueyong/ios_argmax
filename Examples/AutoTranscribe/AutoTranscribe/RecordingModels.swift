//  RecordingModels.swift
//  Recording list data, persistence and waveform extraction for AutoTranscribe.

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
        case .pushToTalk: return "长按语音"
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
            let end = min(start + step, frames)
            var sum: Float = 0
            for i in start..<end { sum += channel[i] * channel[i] }
            values[bar] = Double(sqrt(sum / Float(end - start)))
        }

        let peak = values.max() ?? 0
        guard peak > 0 else { return fallback(bars: bars) }
        return values.map { min(1, max(0.08, $0 / peak)) }
    }

    static func fallback(bars: Int = 48) -> [Double] {
        (0..<bars).map { i in
            0.18 + 0.62 * abs(sin(Double(i) * 0.47) * cos(Double(i) * 0.19))
        }
    }
}

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var items: [RecordingItem] = []

    private let metadataURL: URL
    private let documentsURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documentsURL = docs
        self.metadataURL = docs.appendingPathComponent("recordings.json")
        load()
        if items.isEmpty { seed() }
    }

    var documentsDirectory: URL { documentsURL }

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
            storedName = "recording_\(Int(Date().timeIntervalSince1970)).wav"
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
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([RecordingItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }
}
