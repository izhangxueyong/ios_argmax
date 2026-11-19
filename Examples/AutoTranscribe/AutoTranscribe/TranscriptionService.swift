//  TranscriptionService.swift
//  Loads two bundled WhisperKit CoreML models from the app bundle and
//  transcribes selected audio. No model is downloaded at runtime.
//
//  Modes:
//   * ordinary -> openai_whisper-base                      (Models/whisper-base)
//   * precise  -> openai_whisper-large-v3-v20240930_turbo (Models/whisper-turbo)
//
//  Language handling:
//   * Both are multilingual Whisper checkpoints, so both accept
//     DecodingOptions(language:, task:) and both support X->en translation.
//   * `base` uses the original 99-language tokenizer (no Cantonese `yue`);
//     large-v3-turbo added `yue`, hence 100 codes. LanguageCatalog therefore
//     keeps two separate target lists instead of sharing one.
//   * detectLanguage(audioPath:) reports the source language for the item's
//     info note. For the small base checkpoint the detected code is passed
//     explicitly to DecodingOptions instead of letting the decoder detect it
//     again: an implicit detection pass historically produced only special
//     tokens for whisper-base on CPU-only simulators.

import AVFoundation
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
        case .standard: return "Whisper Base"
        case .precise: return "Whisper Turbo · 632MB"
        }
    }

    var shortModelTitle: String {
        switch self {
        case .standard: return "Whisper Base"
        case .precise: return "Whisper Turbo"
        }
    }

    var folderName: String {
        switch self {
        case .standard: return "whisper-base"
        case .precise: return "whisper-turbo"
        }
    }
}

struct TranscriptionOutcome: Sendable {
    let text: String
    let elapsed: TimeInterval
    /// ISO-639 style code reported by the model, nil when it could not detect one.
    let sourceCode: String?
    /// Raw decoder output when the transcript ended up empty, for CI triage.
    var diagnostic: String? = nil
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
    /// One WhisperKit instance per bundled model folder, loaded lazily.
    private var kits: [String: WhisperKit] = [:]

    var loadedModelSummary: String {
        var loaded: [String] = []
        for mode in TranscriptionMode.allCases {
            if kits[mode.rawValue] != nil { loaded.append(mode.shortModelTitle) }
        }
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
        let kit = try await loadKit(for: mode)

        var detectedCode: String?
        if let detection = try? await kit.detectLanguage(audioPath: audioURL.path) {
            detectedCode = detection.language
        }

        // .translate always emits English; otherwise `language` is a hint about
        // the spoken language and the transcript stays in that language. When
        // the user picked "自动检测", resolve it to the code we just detected
        // so the decoder always receives an explicit language token.
        let task: DecodingTask = target.isTranslation ? .translate : .transcribe
        let language: String? = target.isTranslation
            ? detectedCode
            : (target.languageCode ?? detectedCode)

        // DecodingOptions requires arguments in declaration order:
        // verbose, task, language, ..., detectLanguage, skipSpecialTokens.
        var options = DecodingOptions(
            verbose: true,
            task: task,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true
        )
        if mode == .standard {
            // Whisper Base on a CPU-only simulator yields much lower log-probs
            // than large-v3-turbo. With WhisperKit's default quality thresholds
            // `SegmentSeeker` classifies the whole 30s window as silence and
            // drops every segment, returning an empty transcript even though
            // inference ran for 60-90s. Disable those filters for base only.
            Self.relaxQualityThresholds(&options)
        }
        var results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        var text = Self.joinedText(from: results)
        var diagnostic: String? = nil
        if text.isEmpty { diagnostic = Self.describe(results) }

        // If still empty, try a different decoding strategy with the SAME
        // bundled model: skip the KV-cache prefill prompt and timestamps, and
        // force an explicit English language token.
        if text.isEmpty && !target.isTranslation {
            options = DecodingOptions(
                verbose: true,
                task: .transcribe,
                language: "en",
                usePrefillPrompt: false,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
            if mode == .standard { Self.relaxQualityThresholds(&options) }
            results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
            text = Self.joinedText(from: results)
            diagnostic = (diagnostic ?? "") + " | retry2 " + Self.describe(results)
        }

        return TranscriptionOutcome(
            text: text,
            elapsed: Date().timeIntervalSince(start),
            sourceCode: detectedCode,
            diagnostic: text.isEmpty ? diagnostic : nil
        )
    }

    private static func relaxQualityThresholds(_ options: inout DecodingOptions) {
        options.noSpeechThreshold = nil
        options.logProbThreshold = nil
        options.firstTokenLogProbThreshold = nil
        options.compressionRatioThreshold = nil
    }

    private static func describe(_ results: [TranscriptionResult]) -> String {
        let raw = results.first?.text ?? "(no result)"
        return "segments=\(results.first?.segments.count ?? 0), raw=\(String(raw.prefix(160)))"
    }

    private static func joinedText(from results: [TranscriptionResult]) -> String {
        let fromSegments = results.flatMap { $0.segments }
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !fromSegments.isEmpty { return fromSegments }
        return results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private func loadKit(for mode: TranscriptionMode) async throws -> WhisperKit {
        if let kit = kits[mode.rawValue] { return kit }
        let directory = try bundledModelDirectory(named: mode.folderName)
        let config = WhisperKitConfig(
            modelFolder: directory.path,
            verbose: true,
            logLevel: .info,
            prewarm: false,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        kits[mode.rawValue] = kit
        return kit
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
