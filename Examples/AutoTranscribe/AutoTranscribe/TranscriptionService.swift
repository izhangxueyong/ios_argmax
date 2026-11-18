//  TranscriptionService.swift
//  Loads both ASR models from the app bundle and transcribes selected audio.
//  No model is downloaded at runtime.

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

    var folderName: String {
        switch self {
        case .standard: return "sensevoice-small"
        case .precise: return "whisper-turbo"
        }
    }
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
    private var whisperKit: WhisperKit?

    var loadedModelSummary: String {
        var loaded: [String] = []
        if senseVoiceManager != nil { loaded.append("SenseVoice") }
        if whisperKit != nil { loaded.append("Whisper Turbo") }
        return loaded.isEmpty ? "未加载" : loaded.joined(separator: " + ")
    }

    func transcribe(audioURL: URL, mode: TranscriptionMode) async throws -> String {
        switch mode {
        case .standard:
            return try await transcribeWithSenseVoice(audioURL: audioURL)
        case .precise:
            return try await transcribeWithWhisper(audioURL: audioURL)
        }
    }

    private func transcribeWithSenseVoice(audioURL: URL) async throws -> String {
        if senseVoiceManager == nil {
            let directory = try bundledModelDirectory(named: TranscriptionMode.standard.folderName)
            // fp32 runs on both CPU-only simulators and Neural Engine devices.
            let models = try SenseVoiceModels.load(from: directory, precision: .fp32)
            senseVoiceManager = SenseVoiceManager(models: models)
        }
        guard let manager = senseVoiceManager else {
            throw TranscriptionServiceError.bundledModelMissing("sensevoice-small")
        }
        return try await manager.transcribe(audioURL: audioURL)
    }

    private func transcribeWithWhisper(audioURL: URL) async throws -> String {
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
        let options = DecodingOptions(verbose: true, skipSpecialTokens: true)
        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let text = results.flatMap { $0.segments }
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return text.isEmpty
            ? results.compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            : text
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
