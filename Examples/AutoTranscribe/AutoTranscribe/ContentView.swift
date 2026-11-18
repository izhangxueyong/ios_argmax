//  AutoTranscribe
//  A fully automatic speech-recognition demo:
//  1. Download + load the 632MB large-v3-turbo WhisperKit model
//  2. "Record" a clip (a bundled 16kHz English wav, since the simulator has no mic)
//  3. Transcribe it and display the result
//  Every step writes a log + a completion sentinel into Documents so CI can
//  record the whole run from launch to final result.

import SwiftUI
import WhisperKit
import AVFoundation

struct ContentView: View {
    @State private var stage: Stage = .idle
    @State private var detail = "等待启动"
    @State private var downloadProgress: Double = 0
    @State private var transcript = ""
    @State private var recordSeconds: Double = 0
    @State private var waveform: [CGFloat] = Array(repeating: 0.15, count: 44)
    @State private var player: AVAudioPlayer?
    @State private var started = false
    @State private var modelName = "openai_whisper-large-v3-v20240930_turbo"
    @State private var elapsedText = "0.0s"

    private var modelDisplayName: String { "large-v3-turbo · 632MB" }

    enum Stage: String {
        case idle = "准备就绪"
        case downloading = "下载模型"
        case loading = "加载模型"
        case recording = "录音中"
        case transcribing = "转写中"
        case done = "转写完成"
        case failed = "发生错误"
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            stageCard
            progressBar
            waveformCard
            resultCard
            Spacer(minLength: 4)
            footer
        }
        .padding(22)
        .background(Color(.systemBackground))
        .task {
            guard !started else { return }
            started = true
            await runPipeline()
        }
    }

    // MARK: - UI pieces

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.blue)
            Text("AutoTranscribe")
                .font(.title2.bold())
            Text("自动语音识别 · \(modelDisplayName) · on-device")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 6)
    }

    private var stageCard: some View {
        HStack(spacing: 14) {
            Image(systemName: icon(for: stage))
                .font(.title)
                .foregroundColor(stage == .failed ? .red : (stage == .done ? .green : .blue))
            VStack(alignment: .leading, spacing: 3) {
                Text(stage.rawValue)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if stage == .done || stage == .failed {
                Image(systemName: stage == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(stage == .done ? .green : .red)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("流程").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(elapsedText).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            ProgressView(value: stage == .done ? 1.0 : downloadProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.blue)
        }
    }

    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("录音 / 音频输入", systemImage: "mic.fill")
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.1fs", recordSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(waveform.indices, id: \.self) { i in
                    Capsule()
                        .fill(stage == .recording ? Color.blue : Color.gray.opacity(0.35))
                        .frame(width: 4, height: max(6, waveform[i] * 46))
                }
            }
            .frame(height: 52)
            Text("音频: jfk.wav · 16kHz 单声道 · 11s")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("转写结果", systemImage: "text.bubble.fill")
                    .font(.subheadline.bold())
                Spacer()
                if !transcript.isEmpty { Text("EN").font(.caption2).foregroundColor(.secondary) }
            }
            Text(transcript.isEmpty ? "—" : transcript)
                .font(.body)
                .foregroundColor(transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var footer: some View {
        HStack {
            Text("Model: \(modelName)")
            Spacer()
            Text("Compute: CPU (Simulator)")
        }
        .font(.caption2)
        .foregroundColor(.secondary)
    }

    private func icon(for s: Stage) -> String {
        switch s {
        case .idle: return "play.circle"
        case .downloading: return "arrow.down.circle.fill"
        case .loading: return "cpu.fill"
        case .recording: return "waveform.path.ecg"
        case .transcribing: return "brain"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Pipeline

    private func runPipeline() async {
        let start = Date()
        log("App launched, pipeline started")
        log("Model variant: \(modelName) (\(modelDisplayName))")
        do {
            // Step 1: download the model with progress
            await setStage(.downloading, detail: "从 HuggingFace 下载 large-v3-turbo（约 632MB）…", progress: 0.02)
            let folder = try await WhisperKit.download(
                variant: modelName,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { p in
                    let frac = p.fractionCompleted
                    DispatchQueue.main.async { self.downloadProgress = 0.05 + frac * 0.35 }
                }
            )
            log("Model downloaded to \(folder.lastPathComponent)")

            // Step 2: load model into memory
            await setStage(.loading, detail: "编译并加载 Core ML 模型…", progress: 0.42)
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: true,
                logLevel: .info,
                prewarm: false,
                load: true,
                download: false
            )
            let whisperKit = try await WhisperKit(config)
            log("Model loaded, state=\(whisperKit.modelState)")
            await setStage(.loading, detail: "模型已就绪", progress: 0.5)
            try await Task.sleep(nanoseconds: 600_000_000)

            // Step 3: "record" - play bundled wav with live waveform
            await setStage(.recording, detail: "正在录音（播放内置语音片段）…", progress: 0.55)
            let audioURL = try bundledAudioURL()
            await playClip(url: audioURL)

            // Step 4: transcribe
            await setStage(.transcribing, detail: "正在用 large-v3-turbo 转写…", progress: 0.8)
            log("Transcription started")

            // Use WhisperKit's default decoding path, same as the official FunctionalTests.
            // large-v3-turbo can emit EOT during prompt prefill; the SDK now ignores
            // those throwaway predictions, so keeping prefill enabled is correct.
            // skipSpecialTokens strips the <|startoftranscript|><|en|>... markers
            // and leaves clean readable text.
            let options = DecodingOptions(verbose: true, skipSpecialTokens: true)
            let results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options
            )
            log("Transcription results count: \(results.count), segments: \(results.first?.segments.count ?? 0)")

            // WhisperKit aggregates `result.text` after applying no-speech
            // filtering. On the simulator that filter can blank the aggregate
            // even when the decoder produced a valid segment. Prefer the raw
            // segment texts, which are always populated.
            var text: String = results.flatMap { $0.segments }
                .map { $0.text }
                .joined()
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if text.isEmpty {
                text = results.compactMap { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
            log("Transcription finished: \(text)")

            let seconds = Date().timeIntervalSince(start)
            await MainActor.run {
                self.transcript = text
                self.elapsedText = String(format: "%.1fs", seconds)
                self.stage = .done
                self.detail = "识别完成，共 \(seconds.formatted(.number.precision(.fractionLength(1)))) 秒"
            }
            // Give SwiftUI time to repaint the result on screen BEFORE the CI
            // sees the sentinel, otherwise the recorder stops while the last
            // frame still shows the recording stage.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            writeSentinel(status: "DONE", text: text, seconds: seconds)
        } catch {
            let msg = "\(error)"
            log("FAILED: \(msg)")
            await MainActor.run {
                self.stage = .failed
                self.detail = msg
            }
            writeSentinel(status: "FAILED", text: msg, seconds: Date().timeIntervalSince(start))
        }
    }

    private func setStage(_ s: Stage, detail: String, progress: Double) async {
        await MainActor.run {
            self.stage = s
            self.detail = detail
            if progress > self.downloadProgress { self.downloadProgress = progress }
        }
        log("Stage: \(s.rawValue) - \(detail)")
    }

    private func bundledAudioURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "recording", withExtension: "wav") else {
            throw NSError(domain: "AutoTranscribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "recording.wav not found in bundle"])
        }
        return url
    }

    private func playClip(url: URL) async {
        do {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            await MainActor.run { self.player = p }
            p.play()
            while p.isPlaying {
                let t = p.currentTime
                await MainActor.run {
                    self.recordSeconds = t
                    self.waveform = self.waveform.enumerated().map { i, _ in
                        CGFloat(0.2 + 0.65 * abs(sin(Double(i) * 0.55 + t * 4.0)))
                    }
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            await MainActor.run {
                self.recordSeconds = p.duration
                self.waveform = Array(repeating: 0.15, count: self.waveform.count)
            }
            log("Clip playback finished (\(String(format: "%.1f", p.duration))s)")
        } catch {
            log("Audio playback error: \(error) - continuing to transcription")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: - CI-facing signals (written into the app's Documents dir)

    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = documentsURL().appendingPathComponent("progress.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        print("[AutoTranscribe] \(message)")
    }

    private func writeSentinel(status: String, text: String, seconds: Double) {
        let content = "status=\(status)\nseconds=\(String(format: "%.2f", seconds))\ntext=\(text)\n"
        let url = documentsURL().appendingPathComponent("transcription_done.txt")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
