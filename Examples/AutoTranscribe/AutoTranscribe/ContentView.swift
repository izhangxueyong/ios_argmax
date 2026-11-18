//  AutoTranscribe
//  Two on-device ASR modes with bundled models + a recording list.
//  Models are copied into the app bundle at build time; the app never downloads at runtime.

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = RecordingStore()
    @StateObject private var service = TranscriptionService()

    @State private var selectedMode: TranscriptionMode = .standard
    @State private var stage: Stage = .idle
    @State private var detail = "等待选择录音"
    @State private var progress: Double = 0
    @State private var transcript = ""
    @State private var currentItemName = "—"
    @State private var isRecording = false
    @State private var activeSource: RecordingSource?
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var recordingStartedAt: Date?
    @State private var showingImporter = false
    @State private var started = false

    enum Stage: String {
        case idle = "准备就绪"
        case recording = "录音中"
        case loading = "加载内置模型"
        case transcribing = "转写中"
        case done = "转写完成"
        case failed = "发生错误"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    modeCard
                    controlsCard
                    statusCard
                    resultCard
                    recordingList
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AutoTranscribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
                importAudio(result)
            }
            .task {
                guard !started else { return }
                started = true
                log("App launched")
                if CommandLine.arguments.contains("--auto-run") {
                    selectedMode = .precise
                    setStage(.loading, detail: "准备内置 Whisper Turbo 模型…", progress: 0.05)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let sample = store.bundledSample() {
                        await transcribe(sample)
                    }
                }
            }
        }
    }

    // MARK: - Header / Mode

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 42))
                .foregroundColor(.blue)
            Text("本地语音转写")
                .font(.title2.bold())
            Text("内置模型 · 运行时零下载 · on-device")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别模式").font(.subheadline.bold())
            Picker("识别模式", selection: $selectedMode) {
                ForEach(TranscriptionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Image(systemName: selectedMode == .standard ? "bolt.fill" : "sparkles")
                    .foregroundColor(selectedMode == .standard ? .orange : .purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedMode.modelTitle)
                        .font(.caption.bold())
                    Text("Models/\(selectedMode.folderName) · 已打包进 App")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Recording controls

    private var controlsCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    // Handled by the long-press gesture below.
                } label: {
                    Label(isRecording && activeSource == .pushToTalk ? "松开结束" : "按住说话",
                          systemImage: "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isRecording && activeSource == .pushToTalk ? Color.red.opacity(0.16) : Color.blue.opacity(0.12))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .onLongPressGesture(minimumDuration: 0.1, pressing: { pressing in
                    if pressing {
                        startRecording(source: .pushToTalk)
                    } else if activeSource == .pushToTalk {
                        stopRecording()
                    }
                }, perform: {})

                Button {
                    if isRecording && activeSource == .tap {
                        stopRecording()
                    } else {
                        startRecording(source: .tap)
                    }
                } label: {
                    Label(isRecording && activeSource == .tap ? "停止录音" : "单击录音",
                          systemImage: isRecording && activeSource == .tap ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isRecording && activeSource == .tap ? Color.red.opacity(0.16) : Color(.tertiarySystemGroupedBackground))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }

            Button {
                showingImporter = true
            } label: {
                Label("导入长录音文件", systemImage: "square.and.arrow.down")
                    .font(.subheadline)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Status / Result

    private var statusCard: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon(for: stage))
                    .foregroundColor(stage == .failed ? .red : (stage == .done ? .green : .blue))
                Text(stage.rawValue).font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: progress, total: 1)
                .tint(.blue)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("转写结果", systemImage: "text.bubble.fill")
                    .font(.subheadline.bold())
                Spacer()
                Text(currentItemName).font(.caption2).foregroundColor(.secondary)
            }
            Text(transcript.isEmpty ? "点按下方任一录音开始转写" : transcript)
                .font(.body)
                .foregroundColor(transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            if !transcript.isEmpty {
                Text("已加载模型：\(service.loadedModelSummary)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Recording list

    private var recordingList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("录音列表").font(.headline)
                Spacer()
                Text("\(store.items.count) 条").font(.caption).foregroundColor(.secondary)
            }

            ForEach(RecordingSource.allCases, id: \.self) { source in
                let rows = store.items(for: source)
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.sectionTitle)
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        ForEach(rows) { item in
                            row(for: item, source: source)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for item: RecordingItem, source: RecordingSource) -> some View {
        switch source {
        case .long:
            Button { Task { await transcribe(item) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.rectangle")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.subheadline.bold())
                        Text(item.fileName).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 4)
                    WaveformView(samples: item.waveform, color: .blue, height: 24, barCount: 20)
                        .frame(width: 86)
                    Text(durationText(item.duration)).font(.caption2).foregroundColor(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)

        case .pushToTalk:
            HStack {
                Spacer(minLength: 48)
                Button { Task { await transcribe(item) } } label: {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill").font(.caption).foregroundColor(.white)
                            WaveformView(samples: item.waveform, color: .white.opacity(0.9), height: 22, barCount: 22)
                                .frame(width: 96)
                            Text(durationText(item.duration)).font(.caption2).foregroundColor(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue))
                        Text(item.fileName).font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

        case .tap:
            Button { Task { await transcribe(item) } } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "record.circle").foregroundColor(.red)
                        Text(item.name).font(.subheadline.bold())
                        Spacer()
                        Text(durationText(item.duration)).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(item.fileName).font(.caption2).foregroundColor(.secondary)
                    WaveformView(samples: item.waveform, color: .gray, height: 18, barCount: 40)
                    if let text = item.transcript, !text.isEmpty {
                        Text(text).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func startRecording(source: RecordingSource) {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)

        let url = store.documentsDirectory
            .appendingPathComponent("recording_\(Int(Date().timeIntervalSince1970)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.record()
            recorder = newRecorder
            recordingURL = url
            recordingStartedAt = Date()
            activeSource = source
            isRecording = true
            setStage(.recording, detail: "\(source.sectionTitle)录音中…", progress: 0.08)
            log("Recording started: \(source.rawValue)")
        } catch {
            setStage(.failed, detail: "录音失败：\(error.localizedDescription)", progress: 0)
            log("Recording failed: \(error)")
        }
    }

    private func stopRecording() {
        guard isRecording, let source = activeSource else { return }
        recorder?.stop()
        recorder = nil
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let url = recordingURL
        isRecording = false
        activeSource = nil
        recordingStartedAt = nil
        recordingURL = nil

        guard let url, let data = try? Data(contentsOf: url) else {
            setStage(.idle, detail: "录音未保存", progress: 0)
            return
        }
        let item = store.add(
            name: name(for: source),
            fileName: url.lastPathComponent,
            source: source,
            duration: duration,
            waveform: WaveformExtractor.samples(from: url),
            audioData: data
        )
        setStage(.idle, detail: "已保存「\(item.name)」，点按条目可转写", progress: 0)
        log("Recording saved: \(item.fileName), \(duration)s")
    }

    private func importAudio(_ result: Result<URL, Error>) {
        guard let url = try? result.get() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.deletingPathExtension().lastPathComponent
        let data = try? Data(contentsOf: url)
        let item = store.add(
            name: name,
            fileName: url.lastPathComponent,
            source: .long,
            duration: duration(of: url),
            waveform: WaveformExtractor.samples(from: url),
            audioData: data
        )
        setStage(.idle, detail: "已导入「\(item.name)」，点按条目可转写", progress: 0)
        log("Imported: \(item.fileName)")
    }

    private func transcribe(_ item: RecordingItem) async {
        guard let url = store.audioURL(for: item) else {
            setStage(.failed, detail: "找不到录音文件", progress: 0)
            return
        }
        let start = Date()
        currentItemName = item.name
        transcript = ""
        setStage(.loading, detail: "加载内置 \(selectedMode.modelTitle)…", progress: 0.1)
        log("Transcribe start: \(item.fileName), mode=\(selectedMode.rawValue)")

        do {
            let text = try await service.transcribe(audioURL: url, mode: selectedMode)
            transcript = text
            store.updateTranscript(for: item.id, text: text)
            let seconds = Date().timeIntervalSince(start)
            setStage(.done, detail: "\(selectedMode.title) 完成，共 \(String(format: "%.1f", seconds)) 秒", progress: 1)
            log("Transcribe finished: \(text)")
            writeSentinel(status: "DONE", text: text, seconds: seconds)
        } catch {
            let msg = error.localizedDescription
            setStage(.failed, detail: msg, progress: 0)
            log("Transcribe failed: \(msg)")
            writeSentinel(status: "FAILED", text: msg, seconds: Date().timeIntervalSince(start))
        }
    }

    // MARK: - Helpers

    private func setStage(_ s: Stage, detail: String, progress: Double) {
        stage = s
        self.detail = detail
        self.progress = max(self.progress, progress)
        log("Stage: \(s.rawValue) - \(detail)")
    }

    private func icon(for s: Stage) -> String {
        switch s {
        case .idle: return "play.circle"
        case .recording: return "waveform.path.ecg"
        case .loading: return "shippingbox.fill"
        case .transcribing: return "brain"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func name(for source: RecordingSource) -> String {
        let count = store.items(for: source).count + 1
        switch source {
        case .long: return "长录音 \(count)"
        case .pushToTalk: return "按住说话 \(count)"
        case .tap: return "单击录音 \(count)"
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }

    private func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

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

struct WaveformView: View {
    let samples: [Double]
    var color: Color = .blue
    var height: CGFloat = 28
    var barCount: Int = 32

    private var displayed: [Double] {
        guard samples.count > barCount else { return samples }
        let step = Double(samples.count) / Double(barCount)
        return (0..<barCount).map { i in
            samples[min(samples.count - 1, Int(Double(i) * step))]
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(displayed.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: max(3, displayed[i] * height))
            }
        }
        .frame(height: height)
    }
}
