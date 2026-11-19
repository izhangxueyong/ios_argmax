//  TranscriptionService.swift
//  Loads both ASR models from the app bundle and transcribes selected audio.
//  No model is downloaded at runtime.
//
//  Language handling:
//   * SenseVoice-small takes a FunASR lid_dict embed index (auto/zh/en/yue/ja/ko).
//     transcribeDetailed also reports the detected source-language tag.
//   * Whisper large-v3-turbo takes DecodingOptions(language:, task:). Only the
//     .translate task produces cross-language output (always English).
//     detectLanguage(audioPath:) reports the source language.

import AVFoundation
import FluidAudio
import Foundation
import SwiftUI
import WhisperKit

enum TranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case standard
    case precise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "普通模式"
        case .precise: return "精准模式"
        }
    }

    var modelTitle: String {
        switch self {
        case .standard: return "SenseVoice-small"
        case .precise: return "Whisper Turbo · 632MB"
        }
    }

    var shortModelTitle: String {
        switch self {
        case .standard: return "SenseVoice-small"
        case .precise: return "Whisper Turbo"
        }
    }

    var folderName: String {
        switch self {
        case .standard: return "sensevoice-small"
        case .precise: return "whisper-turbo"
        }
    }
}

struct TranscriptionOutcome: Sendable {
    let text: String
    let elapsed: TimeInterval
    /// ISO-639 style code reported by the model, nil when it could not detect one.
    let sourceCode: String?
}

enum TranscriptionServiceError: LocalizedError {
    case bundledModelMissing(String)
    case noAudioURL

    var errorDescription: String? {
        switch self {
        case .bundledModelMissing(let name):
            return "内置模型缺失：Models/\(name)。请在构建阶段下载模型并打包进 App。"
        case .noAudioURL:
            return "找不到录音文件。"
        }
    }
}

@MainActor
final class TranscriptionService: ObservableObject {
    private var senseVoiceManager: SenseVoiceManager?
    private var senseVoiceLanguage: Int32 = 0
    private var whisperKit: WhisperKit?

    var loadedModelSummary: String {
        var loaded: [String] = []
        if senseVoiceManager != nil { loaded.append("SenseVoice") }
        if whisperKit != nil { loaded.append("Whisper Turbo") }
        return loaded.isEmpty ? "未加载" : loaded.joined(separator: " + ")
    }

    /// Transcribe one recording and report its real wall-clock cost and the
    /// source language the model detected, so the item's info sheet is factual.
    func transcribe(
        audioURL: URL,
        mode: TranscriptionMode,
        target: TranscriptionTarget
    ) async throws -> TranscriptionOutcome {
        let start = Date()
        switch mode {
        case .standard:
            return try await transcribeWithSenseVoice(audioURL: audioURL, target: target, start: start)
        case .precise:
            return try await transcribeWithWhisper(audioURL: audioURL, target: target, start: start)
        }
    }

    private func transcribeWithSenseVoice(
        audioURL: URL,
        target: TranscriptionTarget,
        start: Date
    ) async throws -> TranscriptionOutcome {
        let index = target.senseVoiceIndex ?? 0
        // The language embedding is fixed at init, so rebuild when it changes.
        if senseVoiceManager == nil || senseVoiceLanguage != index {
            let directory = try bundledModelDirectory(named: TranscriptionMode.standard.folderName)
            // fp32 runs on both CPU-only simulators and Neural Engine devices.
            let models = try SenseVoiceModels.load(from: directory, precision: .fp32)
            senseVoiceManager = SenseVoiceManager(models: models, language: index)
            senseVoiceLanguage = index
        }
        guard let manager = senseVoiceManager else {
            throw TranscriptionServiceError.bundledModelMissing("sensevoice-small")
        }
        let converter = AudioConverter(sampleRate: Double(SenseVoiceConfig.sampleRate))
        let samples = try converter.resampleAudioFile(audioURL)
        let detailed = try await manager.transcribeDetailed(audio: samples)
        var text = detailed.text
        if text.isEmpty {
            // Older FluidAudio builds may not expose the detailed API's tags.
            text = try await manager.transcribe(audioURL: audioURL)
        }
        return TranscriptionOutcome(
            text: text,
            elapsed: Date().timeIntervalSince(start),
            sourceCode: detailed.language
        )
    }

    private func transcribeWithWhisper(
        audioURL: URL,
        target: TranscriptionTarget,
        start: Date
    ) async throws -> TranscriptionOutcome {
        if whisperKit == nil {
            let directory = try bundledModelDirectory(named: TranscriptionMode.precise.folderName)
            let config = WhisperKitConfig(
                modelFolder: directory.path,
                verbose: true,
                logLevel: .info,
                prewarm: false,
                load: true,
                download: false
            )
            whisperKit = try await WhisperKit(config)
        }
        guard let kit = whisperKit else {
            throw TranscriptionServiceError.bundledModelMissing("whisper-turbo")
        }

        var detectedCode: String?
        if let detection = try? await kit.detectLanguage(audioPath: audioURL.path) {
            detectedCode = detection.language
        }

        // .translate always emits English; otherwise `language` is a hint about
        // the spoken language and the transcript stays in that language.
        let task: DecodingTask = target.isTranslation ? .translate : .transcribe
        let language: String? = target.isTranslation ? detectedCode : target.languageCode
        let options = DecodingOptions(
            verbose: true,
            task: task,
            language: language,
            skipSpecialTokens: true,
            detectLanguage: language == nil
        )
        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let text = results.flatMap { $0.segments }
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let fallback = results.compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return TranscriptionOutcome(
            text: text.isEmpty ? fallback : text,
            elapsed: Date().timeIntervalSince(start),
            sourceCode: detectedCode
        )
    }

    private func bundledModelDirectory(named name: String) throws -> URL {
        // Xcode copies folder references from a PBXGroup straight into the bundle
        // root (so the model lands at <app>/<name>). If "Models" is ever turned
        // into a folder reference instead, it lands at <app>/Models/<name>.
        // Accept both layouts so bundling works either way.
        if let rootURL = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.fileExists(atPath: rootURL.path) {
            return rootURL
        }
        let nested = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Models") {
            return url
        }
        throw TranscriptionServiceError.bundledModelMissing(name)
    }
}
