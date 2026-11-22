//  TranscriptionService.swift
//  Loads two bundled WhisperKit CoreML models from the app bundle and
//  transcribes selected audio. No model is downloaded at runtime.
//
//  Modes:
//   * ordinary -> openai_whisper-base                      (Models/whisper-base)
//   * precise  -> openai_whisper-large-v3-v20240930_turbo (Models/whisper-turbo)
//
//  Language handling:
//   * Whisper's `language` option is a SOURCE-language hint: "decode this
//     audio as if it were spoken in X". The transcript is emitted in X, not
//     translated into it. There is no X->en translation task in this app.
//   * `base` uses the original 99-language tokenizer (no Cantonese `yue`);
//     large-v3-turbo added `yue`, hence 100 codes. LanguageCatalog therefore
//     keeps two separate language lists instead of sharing one.
//   * If the user picked the wrong language the only fix is to retranscribe
//     with another code; that is handled by the per-item retranscribe sheet.
//  Detect-and-recover: the small base checkpoint running on a CPU-only iOS
//  Simulator used to decode a whole 30s window into timestamp/special tokens
//  (rendered as ">> >> >>") or into nothing at all. For that model only we
//  request a timestamp-free greedy decode with an explicit language token,
//  relax the quality gates in `SegmentSeeker`, and validate that the result
//  contains real words before accepting it. A second pass with a different
//  decoding strategy uses the SAME bundled model, never a different engine.

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
    /// Raw decoder output when the transcript is empty or only special-token
    /// noise, for CI triage. nil when a meaningful transcript was produced.
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
        target: TranscriptionTarget,
        tuning: ModelTuning = .defaults
    ) async throws -> TranscriptionOutcome {
        let start = Date()
        let kit = try await loadKit(for: mode)

        var detectedCode: String?
        if let detection = try? await kit.detectLanguage(audioPath: audioURL.path) {
            detectedCode = detection.language
        }

        // Whisper always transcribes INTO the language it is told the audio is
        // spoken in. When "自动检测" was picked, resolve it to the code we just
        // detected so the decoder always receives an explicit language token.
        let language: String? = target.languageCode ?? detectedCode

        // DecodingOptions requires arguments in declaration order:
        // verbose, task, language, ..., usePrefillPrompt, detectLanguage,
        // skipSpecialTokens, withoutTimestamps.
        let options = Self.makeOptions(
            language: language,
            mode: mode,
            fallback: false,
            tuning: tuning
        )
        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        var text = Self.cleanedText(from: results)
        var diagnostics = ["primary " + Self.describe(results)]

        // A string such as ">> >> >>" is NOT a transcript. Retry with the SAME
        // bundled model and a different decoding strategy, then keep whichever
        // pass produced real words.
        if !Self.isMeaningful(text) {
            let fallbackOptions = Self.makeOptions(
                language: detectedCode ?? language,
                mode: mode,
                fallback: true,
                tuning: tuning
            )
            let retryResults = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: fallbackOptions)
            diagnostics.append("fallback " + Self.describe(retryResults))
            let retryText = Self.cleanedText(from: retryResults)
            if Self.isMeaningful(retryText) { text = retryText }
        }

        let valid = Self.isMeaningful(text)
        return TranscriptionOutcome(
            text: valid ? text : "",
            elapsed: Date().timeIntervalSince(start),
            sourceCode: detectedCode,
            diagnostic: valid ? nil : diagnostics.joined(separator: " | ")
        )
    }

    private static func makeOptions(
        language: String?,
        mode: TranscriptionMode,
        fallback: Bool,
        tuning: ModelTuning
    ) -> DecodingOptions {
        let isBase = mode == .standard
        // `usePrefillPrompt` MUST stay true: when false WhisperKit feeds the
        // decoder only a bare SOT token, dropping the language / task /
        // timestamp prompt entirely (see TranscribeTask.swift).
        var options = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: language,
            temperature: fallback ? Float(tuning.fallbackTemperature) : Float(tuning.temperature),
            temperatureFallbackCount: fallback ? tuning.fallbackCount : tuning.temperatureFallbackCount,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: tuning.skipSpecialTokens,
            withoutTimestamps: isBase && !fallback && tuning.baseWithoutTimestamps
        )
        if isBase && tuning.baseRelaxQualityThresholds {
            // Whisper Base on a CPU-only simulator yields much lower log-probs
            // than large-v3-turbo. With WhisperKit's default quality thresholds
            // `SegmentSeeker` drops every segment; relax them for base only.
            relaxQualityThresholds(&options)
        }
        return options
    }

    private static func relaxQualityThresholds(_ options: inout DecodingOptions) {
        options.noSpeechThreshold = nil
        options.logProbThreshold = nil
        options.firstTokenLogProbThreshold = nil
        options.compressionRatioThreshold = nil
    }

    private static func describe(_ results: [TranscriptionResult]) -> String {
        let raw = results.first?.text ?? "(no result)"
        let segments = results.first?.segments ?? []
        let firstSegment = segments.first?.text ?? ""
        return "segments=\(segments.count), raw=\(String(raw.prefix(160))), seg0=\(String(firstSegment.prefix(80)))"
    }

    /// Strip decoder artefacts before they reach the UI. `skipSpecialTokens`
    /// removes token IDs, but a byte-level BPE decoder can still leave behind
    /// runs of ">" / "<" / "|" that look like ">> >> >>".
    private static func sanitize(_ raw: String) -> String {
        var value = raw
        if let specialTokenPattern = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>") {
            let range = NSRange(value.startIndex..., in: value)
            value = specialTokenPattern.stringByReplacingMatches(
                in: value, options: [], range: range, withTemplate: ""
            )
        }
        let symbols = CharacterSet(charactersIn: "<>|")
        let words = value.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: symbols) }
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// A real transcript contains at least two letters / CJK characters. This
    /// rejects empty strings and pure special-token noise while keeping short
    /// but genuine utterances such as "Hi." or "是的".
    private static func isMeaningful(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters >= 2
    }

    private static func cleanedText(from results: [TranscriptionResult]) -> String {
        let fromSegments = results.flatMap { $0.segments }
            .map { sanitize($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if isMeaningful(fromSegments) { return fromSegments }
        return sanitize(results.map { $0.text }.joined(separator: " "))
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
