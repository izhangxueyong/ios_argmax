//  AutoTranscribe
//  Two on-device ASR modes with bundled models + session-based recording list.
//  Models are copied into the app bundle at build time; the app never downloads at runtime.
//
//  Session rules:
//   - Two hold-to-talk buttons, each bound to its own language, so two people
//     speaking different languages can share ONE open session.
//   - A small checkbox next to the hold-to-talk controls archives that session
//     and opens a new one.
//   - A session detail lists ALL hold-to-talk clips of that same session.
//
//  Whisper language semantics: picking a language tells the model to decode
//  the audio AS that language and output text in that same language. It is not
//  a translation. Picking wrong only affects the transcript, which the user can
//  fix from the exclamation-mark note by retranscribing with another language.
//
//  Every transcription records its model, wall-clock cost, the language the
//  model detected and the language the user asked for. Any item can be
//  retranscribed with a different mode + language (each model exposes its own
//  language catalog).
//
//  Four extra bundled checkpoints drive the timeline and archive search:
//   - Silero VAD int8 marks speech ranges on a thin per-item progress bar.
//   - CAMPPlus compares each range to a mock enrolled "my voice" print and
//     colors it green (me) or orange (someone else).
//   - SenseVoiceSmall int8 gives an on-device second transcript.
//   - EmbeddingGemma Q8_0 GGUF provides 768-d sentence vectors so the archive
//     can be searched by meaning rather than by keyword.
//
//  --auto-run drives a scripted UI demo used by CI:
//    standard mode: 3 hold-to-talk clips in one session, checkbox archive, tap record
//    precise mode:  tap record, 2 hold-to-talk clips in a new session, checkbox, tap record
//    open an item note, show both language catalogs, run two real retranscriptions
//    (one deliberately wrong language, then the corrected pick),
//    scroll the archived list screen by screen, open every session/result detail,
//    and finally return to the home screen.

import AVFoundation
import AutoTranscribeAI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = RecordingStore()
    @StateObject private var service = TranscriptionService()

    @State private var selectedMode: TranscriptionMode = .standard
    @State private var selectedTarget: TranscriptionTarget = LanguageCatalog.defaultTarget(for: .standard)
    @State private var stage: Stage = .idle
    @State private var detail = "等待选择录音"
    @State private var progress: Double = 0
    @State private var transcript = ""
    @State private var currentItemName = "—"
    @State private var isRecording = false
    @State private var activeSource: RecordingSource?
    @State private var activeHoldSlot: Int?
    @State private var activeHoldLanguage: String?
    /// The two hold-to-talk buttons are bound to two (user-selectable) languages.
    @State private var holdLanguages: [String] = ["zh", "en"]
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var recordingStartedAt: Date?
    @State private var showingImporter = false
    @State private var started = false
    @State private var checkPulse = false

    // One sheet is used for result / session detail, item info and retranscribe.
    @State private var reviewTarget: ReviewTarget?
    @State private var demoReplaying = false

    // Retranscription settings live here so the scripted CI demo can drive them.
    @State private var retranscribeMode: TranscriptionMode = .standard
    @State private var retranscribeTarget: TranscriptionTarget = LanguageCatalog.defaultTarget(for: .standard)
    @State private var retranscribeBusy = false
    @State private var retranscribeNote = ""
    @State private var retranscribeResult: TranscriptionMeta?

    // ScrollViewReader anchor used by the scripted demo to reveal the full list.
    @State private var scrollAnchor = ""
    // Monotonic screen marker: CI screenshots every new value.
    @State private var shotStep = 0

    // Four extra on-device checkpoints: VAD timeline, CAMPPlus speaker tags,
    // SenseVoice recognition and EmbeddingGemma archive search.
    @State private var aiStatusLines: [String] = []
    @State private var aiModelLoaded = false
    @State private var enrolledVoiceDimension = 0
    @State private var senseVoicePreview = ""
    @State private var senseVoiceLanguage = ""
    @State private var searchQuery = ""
    @State private var searchHits: [SearchHit] = []
    @State private var indexedDocumentCount = 0
    @State private var searchEngineNote = "尚未建立索引"

    enum Stage: String {
        case idle = "准备就绪"
        case recording = "录音中"
        case loading = "加载内置模型"
        case transcribing = "转写中"
        case done = "转写完成"
        case failed = "发生错误"
    }

    enum ReviewTarget: Identifiable {
        case item(RecordingItem)
        case session(RecordingSession)
        case info(RecordingItem)
        case retranscribe(RecordingItem)

        var id: String {
            switch self {
            case .item(let item): return "item-\(item.id.uuidString)"
            case .session(let session): return "session-\(session.id.uuidString)"
            case .info(let item): return "info-\(item.id.uuidString)"
            case .retranscribe(let item): return "retranscribe-\(item.id.uuidString)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        header.id("top")
                        modeCard.id("mode")
                        controlsCard.id("controls")
                        sessionCard.id("session-card")
                        statusCard.id("status")
                        resultCard.id("result")
                        aiModelsCard.id("ai-models")
                        recordingList.id("archive-list")
                        semanticSearchCard.id("semantic-search")
                        longSection.id("section-long")
                        tapSection.id("section-tap")
                        Color.clear.frame(height: 40).id("list-bottom")
                    }
                    .padding(20)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: scrollAnchor) { _, anchor in
                    guard !anchor.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.7)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
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
            .sheet(item: $reviewTarget) { target in
                ReviewSheet(
                    target: target,
                    sessionItems: sessionItems(for: target),
                    isDemo: demoReplaying,
                    store: store,
                    retranscribeMode: $retranscribeMode,
                    retranscribeTarget: $retranscribeTarget,
                    retranscribeBusy: retranscribeBusy,
                    retranscribeNote: retranscribeNote,
                    retranscribeResult: retranscribeResult,
                    onInfo: { item in reviewTarget = .info(item) },
                    onRetranscribe: { item in
                        retranscribeNote = ""
                        retranscribeResult = nil
                        reviewTarget = .retranscribe(item)
                    },
                    onStartRetranscribe: { item, mode, chosen in
                        Task { await performRetranscribe(item: item, mode: mode, target: chosen) }
                    }
                )
            }
            .task {
                guard !started else { return }
                started = true
                log("App launched")
                if CommandLine.arguments.contains("--auto-run") {
                    Task { await runDemo() }
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
            Text("内置模型 · 运行时零下载 · 会话归档")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别模式").font(.subheadline.bold())
            Picker("识别模式", selection: Binding(
                get: { selectedMode },
                set: { newMode in
                    selectedMode = newMode
                    // The two catalogs are different: never carry an illegal target over.
                    selectedTarget = LanguageCatalog.defaultTarget(for: newMode)
                }
            )) {
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

            Divider()

            HStack {
                Text("识别语言").font(.caption.bold())
                Spacer()
                Picker("识别语言", selection: $selectedTarget) {
                    ForEach(LanguageCatalog.targets(for: selectedMode)) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
            Text(LanguageCatalog.countLabel(for: selectedMode))
                .font(.caption2)
                .foregroundColor(.blue)
            Text("选什么语言，就把录音当作什么语言转写，输出同语种文本；不是翻译。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("选错不会影响原音频：点条目感叹号 → 重新转写 → 重选语言即可。")
                .font(.caption2)
                .foregroundColor(.orange)
            Text(selectedTarget.detail)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Recording controls
    // RED IS A LIVE STATE: a round button turns red only while its own
    // microphone is actually recording. Idle buttons use distinct standby
    // colors (blue / purple / teal) so the recording state is unmistakable.

    private var controlsCard: some View {
        VStack(spacing: 12) {
            recordingStateBanner

            HStack(alignment: .top, spacing: 2) {
                holdToTalkButton(slot: 0)
                Spacer(minLength: 0)
                holdToTalkButton(slot: 1)
                Spacer(minLength: 0)
                tapRecordButton
            }
            .padding(.horizontal, 2)

            holdLanguagePickers

            // A SMALL checkbox, deliberately placed with the hold-to-talk
            // controls: it archives the hold-to-talk session, not a recording.
            newSessionCheckbox

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

    private var recordingStateBanner: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRecording ? Color.red : Color.gray)
                .frame(width: 8, height: 8)
            Text(isRecording ? "正在录音 · 对应按钮变红" : "未在录音 · 按钮为待机色")
                .font(.caption2.bold())
                .foregroundColor(isRecording ? .red : .secondary)
            Spacer(minLength: 2)
            if isRecording {
                Text(activeSource == .tap ? "点击停止" : "松开结束")
                    .font(.caption2.bold())
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(isRecording ? Color.red.opacity(0.12) : Color.gray.opacity(0.10)))
    }

    /// The two hold-to-talk buttons belong to two speakers / two languages.
    /// Both feed the SAME open session; each clip remembers its own language.
    private func holdToTalkButton(slot: Int) -> some View {
        let code = holdLanguages[slot]
        let active = isRecording && activeSource == .pushToTalk && activeHoldSlot == slot
        let standby: Color = slot == 0 ? .blue : .purple
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(active ? Color.red.opacity(0.35) : standby.opacity(0.12))
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(active ? Color.red : standby.opacity(0.75))
                    .frame(width: 66, height: 66)
                    .shadow(color: active ? Color.red.opacity(0.45) : standby.opacity(0.25), radius: 8, y: 4)
                Image(systemName: active ? "waveform.circle.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                if active {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 3)
                        .frame(width: 82, height: 82)
                        .scaleEffect(1.1)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: active)
                }
            }
            .frame(width: 86, height: 86)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 0.15, pressing: { pressing in
                if pressing {
                    startRecording(source: .pushToTalk, holdSlot: slot, holdLanguageCode: code)
                } else if activeSource == .pushToTalk && activeHoldSlot == slot {
                    stopRecording()
                }
            }, perform: {})
            Text(active ? "● 录音中" : "按住说话")
                .font(.caption.bold())
                .foregroundColor(active ? .red : .secondary)
            Text("\(slot == 0 ? "①" : "②") \(LanguageCatalog.shortName(for: code))")
                .font(.caption2.bold())
                .foregroundColor(standby)
        }
        .frame(width: 100)
    }

    private var holdLanguagePickers: some View {
        HStack(spacing: 10) {
            holdLanguageMenu(slot: 0)
            holdLanguageMenu(slot: 1)
        }
    }

    private func holdLanguageMenu(slot: Int) -> some View {
        let tint: Color = slot == 0 ? .blue : .purple
        return HStack(spacing: 4) {
            Text(slot == 0 ? "说话人 1" : "说话人 2")
                .font(.caption2)
                .foregroundColor(.secondary)
            Menu {
                ForEach(LanguageCatalog.targets(for: selectedMode).filter { $0.languageCode != nil }) { option in
                    Button(option.title) {
                        var updated = holdLanguages
                        updated[slot] = option.languageCode ?? "en"
                        holdLanguages = updated
                        log("Hold button \(slot + 1) language = \(updated[slot])")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(LanguageCatalog.shortName(for: holdLanguages[slot]))
                        .font(.caption2.bold())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(tint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.08)))
    }

    private var tapRecordButton: some View {
        let active = isRecording && activeSource == .tap
        let standby: Color = .teal
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(active ? Color.red.opacity(0.35) : standby.opacity(0.12))
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(active ? Color.red : standby.opacity(0.75))
                    .frame(width: 66, height: 66)
                    .shadow(color: active ? Color.red.opacity(0.45) : standby.opacity(0.25), radius: 8, y: 4)
                Image(systemName: active ? "stop.fill" : "record.circle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                if active {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 3)
                        .frame(width: 82, height: 82)
                        .scaleEffect(1.1)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: active)
                }
            }
            .frame(width: 86, height: 86)
            .contentShape(Circle())
            .onTapGesture {
                if isRecording && activeSource == .tap {
                    stopRecording()
                } else if !isRecording {
                    startRecording(source: .tap)
                }
            }
            Text(active ? "● 录音中" : "点击录音")
                .font(.caption.bold())
                .foregroundColor(active ? .red : .secondary)
            Text(active ? "点击停止" : "单击开始 / 单击结束")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(width: 100)
    }

    /// A small checkbox that belongs to the hold-to-talk session. Ticking it
    /// archives the current session and opens the next one.
    private var newSessionCheckbox: some View {
        Button {
            archiveAndOpenNewSession()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checkPulse ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19))
                    .foregroundColor(checkPulse ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("新开会话 · 仅用于按住说话")
                        .font(.caption.bold())
                        .foregroundColor(.primary)
                    Text("勾选即归档当前会话，之后的 ① / ② 录音进入新会话")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 2)
                Text("\(currentSessionClipCount) 段")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var currentSessionClipCount: Int {
        guard let current = store.currentSession else { return 0 }
        return store.items(in: current).count
    }

    // MARK: - Current session card

    private var sessionCard: some View {
        let current = store.currentSession
        var clips: [RecordingItem] = []
        if let current {
            clips = store.items(in: current)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundColor(.orange)
                Text(current?.title ?? "会话")
                    .font(.subheadline.bold())
                Spacer()
                Text("进行中 · 未归档")
                    .font(.caption2.bold())
                    .foregroundColor(.orange)
            }
            Text("① / ② 两个按钮的录音都在本会话；勾选下方「新开会话」才归档，之后进入新会话")
                .font(.caption2)
                .foregroundColor(.secondary)

            if clips.isEmpty {
                Text("暂无说话录音")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(clips.indices, id: \.self) { index in
                    let clip = clips[index]
                    HStack {
                        Text("\(index + 1).")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        Text(clip.name)
                            .font(.caption.bold())
                        Text(clip.fileName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let code = clip.holdLanguageCode {
                            Text(LanguageCatalog.shortName(for: code))
                                .font(.caption2.bold())
                                .foregroundColor(clipColor(for: code))
                        }
                        Spacer(minLength: 4)
                        WaveformView(samples: clip.waveform, color: clipColor(for: clip.holdLanguageCode), height: 16, barCount: 18)
                            .frame(width: 70)
                    }
                }
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
            Text(transcript.isEmpty ? "点按圆形录音键开始" : transcript)
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

    // MARK: - Four bundled on-device models

    private var aiModelsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("端侧四模型状态", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Spacer()
                Text(aiModelLoaded ? "全部就绪" : "待加载")
                    .font(.caption2.bold())
                    .foregroundColor(aiModelLoaded ? .green : .secondary)
            }
            Text("SenseVoiceSmall int8 · Silero VAD int8 · CAMPPlus 声纹 · EmbeddingGemma Q8_0")
                .font(.caption2)
                .foregroundColor(.secondary)
            ForEach(aiStatusLines, id: \.self) { line in
                Text(line)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(line.hasPrefix("MISSING") || line.contains("FAILED") ? .orange : .secondary)
                    .lineLimit(1)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "person.badge.key.fill").foregroundColor(.purple)
                Text(enrolledVoiceDimension > 0
                     ? "已模拟注册「我的声纹」· CAMPPlus \(enrolledVoiceDimension) 维参考向量"
                     : "尚未注册声纹")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text("进度条：灰色=静音，绿色=有语音且是我，橙色=有语音且是他人")
                .font(.caption2)
                .foregroundColor(.blue)
            if !senseVoicePreview.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SenseVoice 端侧识别 · 语言 \(senseVoiceLanguage.isEmpty ? "auto" : senseVoiceLanguage)")
                        .font(.caption2.bold())
                        .foregroundColor(.teal)
                    Text(senseVoicePreview)
                        .font(.caption)
                        .lineLimit(3)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var semanticSearchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("归档语义搜索", systemImage: "magnifyingglass.circle.fill")
                    .font(.headline)
                Spacer()
                Text("EmbeddingGemma 768 维")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("输入自然语言查询，例如 what can I do for my country", text: $searchQuery)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await runSemanticSearch(searchQuery) } }
                Button("搜索") { Task { await runSemanticSearch(searchQuery) } }
                    .font(.caption.bold())
                    .buttonStyle(.borderless)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(.tertiarySystemGroupedBackground)))
            Text("\(searchEngineNote) · 已索引 \(indexedDocumentCount) 条归档 · 按向量余弦相似度排序")
                .font(.caption2)
                .foregroundColor(.blue)
            if searchHits.isEmpty {
                Text("输入查询后可看到最相关的归档录音")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(searchHits.indices, id: \.self) { index in
                    let hit = searchHits[index]
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(index == 0 ? Color.orange : Color.gray))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title).font(.caption.bold())
                            Text(hit.snippet).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(String(format: "%.3f", hit.score))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.orange)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Archived recording list (grouped by session)

    private var recordingList: some View {
        let archived = store.archivedSessions
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("归档录音列表", systemImage: "archivebox.fill")
                    .font(.headline)
                Spacer()
                Text("\(archived.count) 个会话")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("每个会话详情内含该会话全部按住说话录音")
                .font(.caption2)
                .foregroundColor(.secondary)

            if archived.isEmpty {
                Text("还没有归档会话 · 录音后勾选「新开会话」")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            } else {
                ForEach(archived) { session in
                    archivedSessionCard(session)
                        .id("archive-session-\(session.index)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func archivedSessionCard(_ session: RecordingSession) -> some View {
        let clips = store.items(in: session)
        var total: Double = 0
        for clip in clips {
            total += clip.duration
        }
        let wave = WaveformExtractor.merged(clips, bars: 48)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text(session.title)
                    .font(.subheadline.bold())
                Spacer()
                Text("已归档")
                    .font(.caption2.bold())
                    .foregroundColor(.green)
            }
            HStack(spacing: 6) {
                Text("\(clips.count) 段按住说话")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("·").font(.caption2).foregroundColor(.secondary)
                Text(String(format: "总时长 %.1fs", total))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    openSession(session)
                } label: {
                    Text("查看全部 →")
                        .font(.caption2.bold())
                        .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }

            WaveformView(samples: wave, color: .blue, height: 26, barCount: 40)
                .frame(maxWidth: .infinity)

            // Every clip carries its own model badge + info / retranscribe actions.
            ForEach(clips.indices, id: \.self) { index in
                let clip = clips[index]
                let tint = clipColor(for: clip.holdLanguageCode)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Spacer(minLength: 30)
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .font(.caption2)
                                .foregroundColor(.white)
                            Text("\(index + 1). \(clip.name)")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                            if let code = clip.holdLanguageCode {
                                Text(LanguageCatalog.shortName(for: code))
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.white.opacity(0.28)))
                            }
                            WaveformView(samples: clip.waveform, color: .white.opacity(0.9), height: 14, barCount: 14)
                                .frame(width: 54)
                            Text(String(format: "%.1fs", clip.duration))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(tint.opacity(0.9)))
                    }
                    ItemMetaRow(
                        item: clip,
                        onInfo: { openInfo(clip) },
                        onRetranscribe: { openRetranscribe(clip) }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Long / tap sections

    private var longSection: some View {
        let rows = store.items(for: .long)
        return VStack(alignment: .leading, spacing: 10) {
            Text("长录音").font(.subheadline.bold())
            ForEach(rows) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Button { openResult(item) } label: {
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
                    }
                    .buttonStyle(.plain)
                    ItemMetaRow(
                        item: item,
                        onInfo: { openInfo(item) },
                        onRetranscribe: { openRetranscribe(item) }
                    )
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tapSection: some View {
        let rows = store.items(for: .tap)
        return VStack(alignment: .leading, spacing: 10) {
            Text("单击录音").font(.subheadline.bold())
            ForEach(rows) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Button { openResult(item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "record.circle").foregroundColor(.red)
                                Text(item.name).font(.subheadline.bold())
                                Spacer()
                                Text(durationText(item.duration)).font(.caption2).foregroundColor(.secondary)
                            }
                            Text(item.fileName).font(.caption2).foregroundColor(.secondary)
                            WaveformView(samples: item.waveform, color: .red, height: 18, barCount: 40)
                            if let text = item.transcript, !text.isEmpty {
                                Text(text).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    ItemMetaRow(
                        item: item,
                        onInfo: { openInfo(item) },
                        onRetranscribe: { openRetranscribe(item) }
                    )
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Opening details

    private func openResult(_ item: RecordingItem) {
        demoReplaying = false
        currentItemName = item.name
        transcript = item.transcript ?? ""
        reviewTarget = .item(item)
    }

    private func openSession(_ session: RecordingSession) {
        demoReplaying = false
        reviewTarget = .session(session)
    }

    private func openInfo(_ item: RecordingItem) {
        demoReplaying = false
        reviewTarget = .info(item)
    }

    private func openRetranscribe(_ item: RecordingItem) {
        demoReplaying = false
        let initialMode: TranscriptionMode
        if let raw = item.transcription?.modeRaw,
           let parsed = TranscriptionMode(rawValue: raw) {
            initialMode = parsed
        } else {
            initialMode = selectedMode
        }
        retranscribeMode = initialMode
        retranscribeTarget = LanguageCatalog.defaultTarget(for: initialMode)
        retranscribeNote = ""
        retranscribeResult = nil
        reviewTarget = .retranscribe(item)
    }

    private func sessionItems(for target: ReviewTarget) -> [RecordingItem] {
        switch target {
        case .item, .info, .retranscribe:
            return []
        case .session(let session):
            return store.items(in: session)
        }
    }

    private func archiveAndOpenNewSession() {
        let before = store.currentSession?.title ?? "会话"
        guard let archived = store.archiveCurrentSession() else {
            setStage(.idle, detail: "当前还没有说话录音，无需归档", progress: 0)
            return
        }
        let after = store.currentSession?.title ?? "新会话"
        checkPulse = true
        setStage(.done, detail: "✓ 已勾选新开会话 · 归档「\(before)」(\(archived.itemIDs.count) 段)，新建「\(after)」", progress: 1)
        log("Session archived: \(before) clips=\(archived.itemIDs.count), opened \(after)")
        writeText("\(before) archived\n", fileName: "archive_action.log", append: true)
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            checkPulse = false
        }
    }

    // MARK: - Real recording actions

    private func startRecording(
        source: RecordingSource,
        holdSlot: Int? = nil,
        holdLanguageCode: String? = nil
    ) {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)

        let url = store.documentsDirectory
            .appendingPathComponent("recording_\(UUID().uuidString.prefix(8)).wav")
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
            activeHoldSlot = holdSlot
            activeHoldLanguage = holdLanguageCode
            isRecording = true
            let languageNote = holdLanguageCode.map { " · 按 \(LanguageCatalog.shortName(for: $0)) 转写" } ?? ""
            setStage(.recording, detail: "\(source.sectionTitle)录音中…\(languageNote)", progress: 0.08)
            log("Recording started: \(source.rawValue), slot=\(holdSlot.map { String($0) } ?? "-"), lang=\(holdLanguageCode ?? "auto")")
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
        let holdLanguage = activeHoldLanguage
        isRecording = false
        activeSource = nil
        activeHoldSlot = nil
        activeHoldLanguage = nil
        recordingStartedAt = nil
        recordingURL = nil

        guard let url, let data = try? Data(contentsOf: url) else {
            setStage(.idle, detail: "录音未保存", progress: 0)
            return
        }
        let item = store.add(
            name: name(for: source, holdLanguageCode: holdLanguage),
            fileName: url.lastPathComponent,
            source: source,
            duration: duration,
            waveform: WaveformExtractor.samples(from: url),
            audioData: data,
            holdLanguageCode: holdLanguage
        )
        setStage(.idle, detail: "已保存「\(item.name)」到当前会话，点按条目可转写", progress: 0)
        log("Recording saved: \(item.fileName), \(duration)s, lang=\(holdLanguage ?? "auto")")
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

    /// Build the factual metadata shown in the item's exclamation-mark sheet.
    private func makeMeta(
        mode: TranscriptionMode,
        target: TranscriptionTarget,
        outcome: TranscriptionOutcome,
        retranscribeCount: Int
    ) -> TranscriptionMeta {
        let detected = outcome.sourceCode.map { LanguageCatalog.displayName(for: $0) } ?? "未检出"
        // What the user asked for, NOT a translation target.
        let chosen = LanguageCatalog.displayName(for: target.languageCode)
        return TranscriptionMeta(
            modelName: mode.modelTitle,
            modeTitle: mode.title,
            modeRaw: mode.rawValue,
            elapsed: outcome.elapsed,
            sourceLanguage: detected,
            targetLanguage: chosen,
            taskTitle: "按所选语言转写 · 同语种输出（非翻译）",
            retranscribeCount: retranscribeCount,
            finishedAt: Date()
        )
    }

    private func transcribe(_ item: RecordingItem) async {
        guard let url = store.audioURL(for: item) else {
            setStage(.failed, detail: "找不到录音文件", progress: 0)
            return
        }
        let mode = selectedMode
        // A hold-to-talk clip carries the language of the button that recorded
        // it. That language wins over the global picker for this one clip.
        let target: TranscriptionTarget
        if let code = item.holdLanguageCode,
           let matched = LanguageCatalog.targets(for: mode).first(where: { $0.languageCode == code }) {
            target = matched
        } else {
            target = LanguageCatalog.validated(selectedTarget, for: mode)
        }
        currentItemName = item.name
        transcript = ""
        setStage(.loading, detail: "加载内置 \(mode.modelTitle)…", progress: 0.1)
        log("Transcribe start: \(item.fileName), mode=\(mode.rawValue), language=\(target.id) (from \(item.holdLanguageCode ?? "global picker"))")

        do {
            let outcome = try await service.transcribe(audioURL: url, mode: mode, target: target)
            transcript = outcome.text
            let meta = makeMeta(
                mode: mode,
                target: target,
                outcome: outcome,
                retranscribeCount: item.transcription?.retranscribeCount ?? 0
            )
            store.updateTranscription(for: item.id, text: outcome.text, meta: meta)
            setStage(.done, detail: "\(mode.title) · \(target.title) 完成，共 \(String(format: "%.1f", outcome.elapsed)) 秒", progress: 1)
            log("Transcribe finished: model=\(meta.modelName), elapsed=\(meta.elapsed), \(meta.direction), text=\(outcome.text)")
            if let diagnostic = outcome.diagnostic {
                log("INVALID TRANSCRIPT diagnostic: \(diagnostic)")
            }
            writeSentinel(status: "DONE", text: outcome.text, seconds: outcome.elapsed)
        } catch {
            let msg = error.localizedDescription
            setStage(.failed, detail: msg, progress: 0)
            log("Transcribe failed: \(msg)")
            writeSentinel(status: "FAILED", text: msg, seconds: 0)
        }
    }

    /// Re-run one archived item with a user-selected model + target language.
    private func performRetranscribe(
        item: RecordingItem,
        mode: TranscriptionMode,
        target: TranscriptionTarget
    ) async {
        guard let url = store.audioURL(for: item) else {
            retranscribeNote = "找不到录音文件"
            return
        }
        let validated = LanguageCatalog.validated(target, for: mode)
        retranscribeBusy = true
        retranscribeResult = nil
        retranscribeNote = "正在用 \(mode.modelTitle) · \(validated.title) 重新转写…"
        setStage(.loading, detail: retranscribeNote, progress: 0.15)
        log("RETRANSCRIBE start: \(item.fileName), mode=\(mode.rawValue), target=\(validated.id)")

        do {
            let outcome = try await service.transcribe(audioURL: url, mode: mode, target: validated)
            let meta = makeMeta(
                mode: mode,
                target: validated,
                outcome: outcome,
                retranscribeCount: (item.transcription?.retranscribeCount ?? 0) + 1
            )
            store.updateTranscription(for: item.id, text: outcome.text, meta: meta)
            transcript = outcome.text
            currentItemName = item.name
            retranscribeResult = meta
            retranscribeBusy = false
            retranscribeNote = "✓ 重新转写完成 · \(meta.modelName) · \(meta.elapsedTitle)"
            setStage(.done, detail: retranscribeNote, progress: 1)
            log("RETRANSCRIBE done: \(item.fileName), model=\(meta.modelName), elapsed=\(meta.elapsed), \(meta.direction), text=\(outcome.text)")
            if let diagnostic = outcome.diagnostic {
                log("INVALID RETRANSCRIPT diagnostic: \(diagnostic)")
            }
            writeText(
                "\(item.fileName) retranscribed model=\(meta.modelName) target=\(validated.id) seconds=\(String(format: "%.1f", meta.elapsed))\n",
                fileName: "retranscribe_action.log",
                append: true
            )
        } catch {
            let msg = error.localizedDescription
            retranscribeBusy = false
            retranscribeNote = "重新转写失败：\(msg)"
            setStage(.failed, detail: retranscribeNote, progress: 0)
            log("RETRANSCRIBE failed: \(msg)")
        }
    }

    // MARK: - Scripted demo (CI)

    private func runDemo() async {
        log("DEMO started")

        // Capture the idle controls: standby colors, two language buttons and
        // the small "new session" checkbox. No button is red yet.
        markScreen("home controls · 待机色 / 双语言按住按钮 / 新开会话勾选框")
        try? await Task.sleep(nanoseconds: 6_000_000_000)

        // Load all four bundled checkpoints, enroll a mock "my voice" print
        // and probe SenseVoice before any clip is recorded.
        await prepareAIModels()

        // ---- Standard mode: three hold-to-talk clips in ONE session ----
        // The two speakers alternate: ① Chinese, ② English, ① Chinese.
        selectedMode = .standard
        selectedTarget = LanguageCatalog.defaultTarget(for: .standard)
        await demoRecord(source: .pushToTalk, holdSlot: 0, label: "普通 · 会话1 ①中文 1/3")
        await demoRecord(source: .pushToTalk, holdSlot: 1, label: "普通 · 会话1 ②English 2/3")
        await demoRecord(source: .pushToTalk, holdSlot: 0, label: "普通 · 会话1 ①中文 3/3")
        await demoCheckmark(label: "普通 · 勾选新开会话 / 归档会话1")
        await demoRecord(source: .tap, label: "普通 · 单击录音")

        // ---- Precise mode ----
        selectedMode = .precise
        selectedTarget = LanguageCatalog.defaultTarget(for: .precise)
        await demoRecord(source: .tap, label: "精准 · 单击录音 1/2")
        await demoRecord(source: .pushToTalk, holdSlot: 1, label: "精准 · 会话2 ②English 1/2")
        await demoRecord(source: .pushToTalk, holdSlot: 0, label: "精准 · 会话2 ①中文 2/2")
        await demoCheckmark(label: "精准 · 勾选新开会话 / 归档会话2")
        await demoRecord(source: .tap, label: "精准 · 单击录音 2/2")

        // ---- Item notes + "wrong language -> pick again" retranscriptions ----
        await demoModelInfoFlow()

        // ---- EmbeddingGemma index + real semantic queries ----
        await demoSemanticSearch()

        // ---- Scroll down the archived list screen by screen ----
        await demoScrollArchivedList()

        // ---- Open every saved result detail, then return ----
        await demoReviewResults()

        // ---- Return to home: leave the archived list fully in view ----
        scrollAnchor = "archive-list"
        stage = .done
        detail = "演示完成 · 已返回桌面（归档录音列表）"
        log("DEMO finished")
        markScreen("final archived list")
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        writeDemoSentinel(status: "DONE", sessions: store.archivedSessions.count, items: store.items.count)
    }

    /// Bump a monotonic marker; the CI watcher screenshots each new value.
    private func markScreen(_ label: String) {
        shotStep += 1
        writeText("\(shotStep)\n", fileName: "archive_scroll_step.txt")
        log("DEMO screen \(shotStep): \(label)")
    }

    private func demoRecord(source: RecordingSource, holdSlot: Int? = nil, label: String) async {
        setStage(.idle, detail: "准备 \(label)…", progress: 0.02)
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Drive the SAME state the real button uses, so the button really turns
        // red in the CI recording instead of just logging a fake step.
        let holdLanguage = holdSlot.map { holdLanguages[$0] }
        activeSource = source
        activeHoldSlot = holdSlot
        activeHoldLanguage = holdLanguage
        isRecording = true
        setStage(.recording, detail: "\(label) · 录音中（按钮变红）…", progress: 0.06)
        log("DEMO recording started: \(label), lang=\(holdLanguage ?? "global picker")")
        markScreen("\(label) · 录音中 · 红色状态")
        // Keep the live state up long enough for the CI watcher (2s poll +
        // 2s settle) to capture a red-button frame, not just the video.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        isRecording = false
        activeSource = nil
        activeHoldSlot = nil
        activeHoldLanguage = nil

        guard let sampleURL = Bundle.main.url(forResource: "recording", withExtension: "wav"),
              let data = try? Data(contentsOf: sampleURL) else {
            setStage(.failed, detail: "内置示例音频缺失", progress: 0)
            log("DEMO failed: bundled sample missing")
            return
        }

        let number = store.items.count + 1
        let fileName = "\(source.rawValue)_\(number).wav"
        let item = store.add(
            name: name(for: source, holdLanguageCode: holdLanguage),
            fileName: fileName,
            source: source,
            duration: duration(of: sampleURL),
            waveform: WaveformExtractor.samples(from: sampleURL),
            audioData: data,
            holdLanguageCode: holdLanguage
        )
        log("DEMO recording saved: \(item.fileName) in \(store.currentSession?.title ?? "session"), lang=\(holdLanguage ?? "global")")

        try? await Task.sleep(nanoseconds: 400_000_000)
        currentItemName = item.name
        await transcribe(item)
        // Silero VAD timeline + CAMPPlus speaker verdict + SenseVoice text.
        await analyzeRecording(item, audioURL: sampleURL)
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    private func demoCheckmark(label: String) async {
        setStage(.idle, detail: "准备 \(label)…", progress: 0.2)
        try? await Task.sleep(nanoseconds: 700_000_000)
        checkPulse = true
        let before = store.currentSession?.title ?? "会话"
        guard let archived = store.archiveCurrentSession() else {
            log("DEMO checkbox: nothing to archive")
            checkPulse = false
            return
        }
        let after = store.currentSession?.title ?? "新会话"
        setStage(.done, detail: "✓ 已勾选新开会话 · 归档「\(before)」(\(archived.itemIDs.count) 段)，新建「\(after)」", progress: 1)
        log("DEMO checkbox: archived \(before) clips=\(archived.itemIDs.count), opened \(after)")
        writeText("\(before) archived with \(archived.itemIDs.count) clips\n", fileName: "archive_action.log", append: true)
        markScreen("勾选新开会话 · \(before) -> \(after) · 勾选框已打勾")
        try? await Task.sleep(nanoseconds: 4_500_000_000)
        checkPulse = false
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Show the note, both per-model language catalogs, and a REAL
    /// "picked the wrong language -> retranscribe -> pick again" recovery.
    private func demoModelInfoFlow() async {
        let taps = store.items(for: .tap)
        guard let newestTap = taps.first, let oldestTap = taps.last else { return }
        demoReplaying = true

        // 1) Note: model, elapsed, detected language vs the language asked for.
        reviewTarget = .info(newestTap)
        await settleThenMark("备注 · 模型 / 用时 / 检测语言 · 指定语言", seconds: 6)

        // 2) STANDARD mode sheet: Whisper Base offers 99 languages, because
        //    the original Whisper tokenizer has no Cantonese `yue`.
        retranscribeNote = ""
        retranscribeResult = nil
        retranscribeMode = .standard
        let baseEnglish = LanguageCatalog.baseTargets.first { $0.id == "en" }
            ?? LanguageCatalog.defaultTarget(for: .standard)
        let baseFrench = LanguageCatalog.baseTargets.first { $0.id == "fr" }
            ?? baseEnglish
        retranscribeTarget = baseEnglish
        reviewTarget = .retranscribe(newestTap)
        await settleThenMark("重新转写 · 普通模式 Whisper Base · 99 种识别语言（不含粤语）", seconds: 6)

        // 3) PRECISE mode sheet: large-v3-turbo adds Cantonese -> 100 codes.
        retranscribeMode = .precise
        let cantonese = LanguageCatalog.turboTargets.first { $0.id == "yue" }
            ?? LanguageCatalog.defaultTarget(for: .precise)
        let turboEnglish = LanguageCatalog.turboTargets.first { $0.id == "en" }
            ?? LanguageCatalog.defaultTarget(for: .precise)
        retranscribeTarget = cantonese
        await settleThenMark("重新转写 · 精准模式 Whisper Turbo · 100 种识别语言含粤语", seconds: 6)

        // 4) Deliberately pick the WRONG language for the English JFK sample.
        //    Whisper will decode English audio AS French; it is not a translation.
        retranscribeMode = .standard
        retranscribeTarget = baseFrench
        await settleThenMark("演示选错语言 · 把英语录音当作法语转写（非翻译）", seconds: 5)
        await performRetranscribe(item: newestTap, mode: .standard, target: baseFrench)
        await settleThenMark("重新转写完成 · 选错语言的结果", seconds: 5)

        // 5) The note flags the mismatch and tells the user to pick again.
        let wrong = store.item(with: newestTap.id) ?? newestTap
        reviewTarget = .info(wrong)
        await settleThenMark("备注 · 检测英语 / 指定法语 不一致 · 提示可重转重选", seconds: 6)

        // 6) Re-pick the correct language on another item and really re-run.
        retranscribeNote = ""
        retranscribeResult = nil
        retranscribeMode = .precise
        retranscribeTarget = turboEnglish
        reviewTarget = .retranscribe(oldestTap)
        await settleThenMark("重新转写 · 重选正确语言 英语(en) · 精准模式", seconds: 5)
        await performRetranscribe(item: oldestTap, mode: .precise, target: turboEnglish)
        await settleThenMark("重新转写完成 · 重选语言后的结果", seconds: 6)

        let corrected = store.item(with: oldestTap.id) ?? oldestTap
        reviewTarget = .info(corrected)
        await settleThenMark("备注已更新 · 指定语言与检测语言一致", seconds: 6)

        reviewTarget = nil
        demoReplaying = false
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    /// Let a sheet finish presenting BEFORE bumping the marker, so the CI
    /// watcher (which waits 2s) never captures a half-animated transition.
    private func settleThenMark(_ label: String, seconds: UInt64) async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        markScreen(label)
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }

    /// Scroll the archived recording list one screen at a time so the whole
    /// list is visible in the recording. A marker file lets CI capture one
    /// still per screen.
    private func demoScrollArchivedList() async {
        writeText("started\n", fileName: "archive_scroll_started.txt")
        log("DEMO archive scroll started")
        exportArchiveSnapshot()

        var anchors: [String] = ["session-card", "ai-models", "archive-list", "semantic-search"]
        for session in store.archivedSessions {
            anchors.append("archive-session-\(session.index)")
        }
        anchors.append("section-long")
        anchors.append("section-tap")
        anchors.append("list-bottom")

        for (index, anchor) in anchors.enumerated() {
            scrollAnchor = anchor
            let step = index + 1
            markScreen("archive list scroll \(step)/\(anchors.count) -> \(anchor)")
            setStage(.done, detail: "下滑查看归档录音列表 · 第 \(step)/\(anchors.count) 屏", progress: 1)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }

        writeText("done\n", fileName: "archive_scroll_done.txt")
        log("DEMO archive scroll done")
    }

    private func demoReviewResults() async {
        demoReplaying = true

        // Open every archived session detail first: each one shows ALL of that
        // session's hold-to-talk clips.
        let sessions = store.archivedSessions
        for (index, session) in sessions.enumerated() {
            let clips = store.items(in: session)
            setStage(.done, detail: "查看会话详情 \(index + 1)/\(sessions.count) · \(session.title)（\(clips.count) 段）", progress: 1)
            reviewTarget = .session(session)
            log("DEMO review session \(index + 1)/\(sessions.count): \(session.title) with \(clips.count) clips")
            markScreen("session detail \(session.title) with \(clips.count) clips")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            reviewTarget = nil
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        // Then every standalone result (long + tap recordings).
        let singles = store.items.filter { $0.source != .pushToTalk }
        for (index, item) in singles.enumerated() {
            transcript = item.transcript ?? ""
            currentItemName = item.name
            setStage(.done, detail: "查看结果 \(index + 1)/\(singles.count) · \(item.name)", progress: 1)
            reviewTarget = .item(item)
            log("DEMO review item \(index + 1)/\(singles.count): \(item.name)")
            markScreen("result detail \(item.name)")
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            reviewTarget = nil
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        demoReplaying = false
    }

    // MARK: - On-device AI helpers (SenseVoice / VAD / CAMPPlus / EmbeddingGemma)

    private func prepareAIModels() async {
        let ai = AudioIntelligence.shared
        ai.configure()
        ai.enrollMockVoice()
        aiStatusLines = ai.statusLines
        aiModelLoaded = ai.statusLines.filter { $0.hasPrefix("OK") }.count >= 5
        enrolledVoiceDimension = ai.registeredVoiceDimension
        for line in ai.statusLines { log("AI model: \(line)") }
        log("AI encoder: \(ai.encoderInfo)")

        if let sample = Bundle.main.url(forResource: "recording", withExtension: "wav") {
            let probe = ai.senseVoiceTranscribe(audioURL: sample)
            if !probe.text.isEmpty {
                senseVoicePreview = probe.text
                senseVoiceLanguage = probe.language
            }
            log("SenseVoice probe: lang=\(probe.language) text=\(probe.text) note=\(probe.note)")
        }
        markScreen("端侧四模型加载 · 声纹模拟注册 · SenseVoice 试跑")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }

    private func analyzeRecording(_ item: RecordingItem, audioURL: URL) async {
        let ai = AudioIntelligence.shared
        let analysis = ai.analyze(audioURL: audioURL)
        store.updateAnalysis(for: item.id, analysis: analysis)
        let mine = analysis.segments.filter(\.isMe).count
        log("VAD/CAMPPlus \(item.fileName): segments=\(analysis.segments.count) me=\(mine) note=\(analysis.engineNote)")
        for segment in analysis.segments.prefix(4) {
            log(String(format: "  VAD segment %.2f-%.2fs score=%.3f me=%@",
                       segment.start, segment.end, segment.similarity,
                       segment.isMe ? "YES" : "NO"))
        }
        let sense = ai.senseVoiceTranscribe(audioURL: audioURL)
        if !sense.text.isEmpty {
            store.updateSenseVoice(for: item.id, text: sense.text, language: sense.language)
            senseVoicePreview = sense.text
            senseVoiceLanguage = sense.language
            log("SenseVoice \(item.fileName): lang=\(sense.language) text=\(sense.text)")
        } else {
            log("SenseVoice \(item.fileName): empty, \(sense.note)")
        }
    }

    private func rebuildSearchIndex() async {
        let documents = store.items.map { item -> (id: String, title: String, text: String) in
            let parts = [item.transcript, item.senseVoiceText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            return (
                id: item.id.uuidString,
                title: item.name,
                text: parts.isEmpty ? item.name : parts.joined(separator: " ")
            )
        }
        let indexed = AudioIntelligence.shared.buildIndex(from: documents)
        for document in indexed {
            if let uuid = UUID(uuidString: document.id) {
                store.updateSearchVector(for: uuid, vector: document.vector)
            }
        }
        indexedDocumentCount = indexed.count
        searchEngineNote = indexed.isEmpty
            ? "EmbeddingGemma 不可用"
            : "EmbeddingGemma Q8_0 · 768 维词向量池化"
        log("Search index built: \(indexed.count) docs, dim=\(indexed.first?.vector.count ?? 0), \(searchEngineNote)")
    }

    private func runSemanticSearch(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchQuery = query
        // Build the document list explicitly. Xcode 16.4's Swift compiler
        // mis-infers compactMap's closure result as non-optional here, which
        // makes `return nil` a hard error; a plain loop is unambiguous.
        var documents: [IndexedDocument] = []
        for item in store.items {
            guard let vector = item.searchVector else { continue }
            let parts = [item.transcript, item.senseVoiceText].compactMap { $0 }
            documents.append(IndexedDocument(
                id: item.id.uuidString,
                title: item.name,
                text: parts.joined(separator: " "),
                vector: vector
            ))
        }
        let hits = AudioIntelligence.shared.search(query: query, in: documents)
        searchHits = hits
        log("Semantic search [\(query)]: \(hits.count) hits")
        for hit in hits.prefix(5) {
            log(String(format: "  hit score=%.4f %@ | %@", hit.score, hit.title, hit.snippet))
        }
    }

    private func demoSemanticSearch() async {
        scrollAnchor = "semantic-search"
        setStage(.loading, detail: "用 EmbeddingGemma 为全部归档生成 768 维向量…", progress: 0.9)
        markScreen("EmbeddingGemma · 为归档建立向量索引")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await rebuildSearchIndex()
        await runSemanticSearch("what can I do for my country")
        markScreen("语义搜索 · what can I do for my country · 余弦相似度排序")
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        await runSemanticSearch("国家 演讲 责任")
        markScreen("语义搜索 · 中文查询 国家 演讲 责任")
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        await runSemanticSearch("my fellow Americans")
        markScreen("语义搜索 · my fellow Americans")
        try? await Task.sleep(nanoseconds: 5_000_000_000)
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

    private func name(for source: RecordingSource, holdLanguageCode: String? = nil) -> String {
        let count = store.items(for: source).count + 1
        switch source {
        case .long: return "长录音 \(count)"
        case .pushToTalk:
            let sessionTitle = store.currentSession?.title ?? "会话"
            let clipCount = currentSessionClipCount + 1
            let language = holdLanguageCode.map { " · \(LanguageCatalog.shortName(for: $0))" } ?? ""
            return "\(sessionTitle) · 说话 \(clipCount)\(language)"
        case .tap: return "单击录音 \(count)"
        }
    }

    private func clipColor(for code: String?) -> Color {
        LanguageCatalog.tint(for: code)
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
        writeText(line, fileName: "progress.log", append: true)
        print("[AutoTranscribe] \(message)")
    }

    private func writeText(_ text: String, fileName: String, append: Bool = false) {
        let url = documentsURL().appendingPathComponent(fileName)
        if append, let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func writeSentinel(status: String, text: String, seconds: Double) {
        let content = "status=\(status)\nseconds=\(String(format: "%.2f", seconds))\ntext=\(text)\n"
        writeText(content, fileName: "transcription_done.txt")
    }

    private func writeDemoSentinel(status: String, sessions: Int, items: Int) {
        let content = "status=\(status)\nsessions=\(sessions)\nitems=\(items)\n"
        writeText(content, fileName: "demo_done.txt")
    }

    /// Render the whole archived list into one tall PNG, so the complete list
    /// can be reviewed without being cut off by the screen height.
    private func exportArchiveSnapshot() {
        var sections: [ArchiveSnapshotSection] = []
        for session in store.archivedSessions {
            let clips = store.items(in: session)
            sections.append(ArchiveSnapshotSection(session: session, clips: clips))
        }
        let totalCount = store.items.count
        let snapshot = ArchiveSnapshotView(
            sections: sections,
            longItems: store.items(for: .long),
            tapItems: store.items(for: .tap),
            totalCount: totalCount
        )
        .frame(width: 390, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.systemGroupedBackground))
        let renderer = ImageRenderer(content: snapshot)
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else {
            log("Archive snapshot render failed")
            return
        }
        let url = documentsURL().appendingPathComponent("archive_list_full.png")
        try? data.write(to: url, options: .atomic)
        log("Archive snapshot exported: \(sections.count) sessions, \(totalCount) items")
    }
}

// MARK: - Full-height snapshot of the archived recording list

struct ArchiveSnapshotSection: Identifiable {
    let id: UUID
    let session: RecordingSession
    let clips: [RecordingItem]

    init(session: RecordingSession, clips: [RecordingItem]) {
        self.id = session.id
        self.session = session
        self.clips = clips
    }
}

struct ArchiveSnapshotView: View {
    let sections: [ArchiveSnapshotSection]
    let longItems: [RecordingItem]
    let tapItems: [RecordingItem]
    let totalCount: Int

    private func metaLine(_ item: RecordingItem) -> String {
        guard let meta = item.transcription else { return "未转写" }
        return "\(meta.modelName) · \(meta.elapsedTitle) · \(meta.direction)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("归档录音列表 · 完整视图")
                    .font(.title3.bold())
                Text("共 \(sections.count) 个已归档会话 · \(totalCount) 条录音 · 全部保存在本地")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("每条录音下方标注：使用模型 · 转写用时 · 检测语言 / 指定语言")
                    .font(.caption2)
                    .foregroundColor(.blue)
                Text("细进度条 = Silero VAD 语音区间 · 绿色「我」/ 橙色「他人」= CAMPPlus 声纹判定")
                    .font(.caption2)
                    .foregroundColor(.green)
            }

            ForEach(sections) { section in
                snapshotSession(section)
            }

            snapshotSection(title: "长录音", rows: longItems, color: .blue)
            snapshotSection(title: "单击录音", rows: tapItems, color: .teal)

            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("以上为全部归档内容 · 演示结束")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func snapshotSession(_ section: ArchiveSnapshotSection) -> some View {
        let session = section.session
        let clips = section.clips
        var total: Double = 0
        for clip in clips {
            total += clip.duration
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text(session.title).font(.headline)
                Spacer()
                Text("已归档 · \(clips.count) 段按住说话 · \(String(format: "%.1f", total))s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            ForEach(clips.indices, id: \.self) { index in
                let clip = clips[index]
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.name).font(.caption.bold())
                            Text(clip.fileName)
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                            Text(metaLine(clip))
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        WaveformView(samples: clip.waveform, color: .red, height: 18, barCount: 20)
                            .frame(width: 90)
                        Text(String(format: "%.1fs", clip.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    if let analysis = clip.voiceTimeline {
                        VoiceTimelineView(analysis: analysis, duration: clip.duration)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func snapshotSection(title: String, rows: [RecordingItem], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.caption.bold())
                            Text(item.fileName)
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                            Text(metaLine(item))
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        WaveformView(samples: item.waveform, color: color, height: 18, barCount: 20)
                            .frame(width: 90)
                        Text(String(format: "%.1fs", item.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    if let analysis = item.voiceTimeline {
                        VoiceTimelineView(analysis: analysis, duration: item.duration)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }
}

// MARK: - Per-item model badge + info / retranscribe actions

struct ItemMetaRow: View {
    let item: RecordingItem
    let onInfo: () -> Void
    let onRetranscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text(item.modelBadge)
                        .font(.caption2.bold())
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(item.transcription == nil ? Color.gray.opacity(0.18) : Color.blue.opacity(0.14)))
                .foregroundColor(item.transcription == nil ? Color.secondary : Color.blue)

                if let meta = item.transcription {
                    Text(meta.elapsedTitle)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: onInfo) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                Button(action: onRetranscribe) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 19))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }
            if let analysis = item.voiceTimeline {
                VoiceTimelineView(analysis: analysis, duration: item.duration)
            }
        }
    }
}

// MARK: - Fine VAD timeline with CAMPPlus "is it me?" tags

struct VoiceTimelineView: View {
    let analysis: AudioAnalysis
    let duration: TimeInterval

    private var total: Double { max(analysis.duration, duration, 0.01) }
    private var mineCount: Int { analysis.segments.filter(\.isMe).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.22))
                        .frame(height: 9)
                    ForEach(analysis.segments.indices, id: \.self) { index in
                        let segment = analysis.segments[index]
                        let startX = CGFloat(segment.start / total) * geometry.size.width
                        let width = max(CGFloat((segment.end - segment.start) / total) * geometry.size.width, 3)
                        Capsule()
                            .fill(segment.isMe ? Color.green : Color.orange)
                            .frame(width: width, height: 9)
                            .offset(x: startX)
                    }
                }
            }
            .frame(height: 9)
            HStack(spacing: 7) {
                Text("VAD \(analysis.segments.count) 段")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("我 \(mineCount)").font(.caption2).foregroundColor(.secondary)
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("他人 \(analysis.segments.count - mineCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1fs", total))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            if let first = analysis.segments.first {
                Text(String(format: "首段 %.2f–%.2fs · 声纹相似度 %.2f · %@",
                            first.start, first.end, first.similarity,
                            first.isMe ? "判定为我" : "判定为他人"))
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
            Text(analysis.engineNote)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Review sheet dispatcher

struct ReviewSheet: View {
    let target: ContentView.ReviewTarget
    let sessionItems: [RecordingItem]
    let isDemo: Bool
    @ObservedObject var store: RecordingStore
    @Binding var retranscribeMode: TranscriptionMode
    @Binding var retranscribeTarget: TranscriptionTarget
    let retranscribeBusy: Bool
    let retranscribeNote: String
    let retranscribeResult: TranscriptionMeta?
    let onInfo: (RecordingItem) -> Void
    let onRetranscribe: (RecordingItem) -> Void
    let onStartRetranscribe: (RecordingItem, TranscriptionMode, TranscriptionTarget) -> Void

    var body: some View {
        Group {
            switch target {
            case .item(let item):
                ResultDetailView(
                    item: store.item(with: item.id) ?? item,
                    isDemo: isDemo,
                    store: store,
                    onInfo: onInfo,
                    onRetranscribe: onRetranscribe
                )
            case .session(let session):
                SessionDetailView(
                    session: session,
                    items: sessionItems,
                    isDemo: isDemo,
                    store: store,
                    onInfo: onInfo,
                    onRetranscribe: onRetranscribe
                )
            case .info(let item):
                ItemInfoView(
                    item: store.item(with: item.id) ?? item,
                    onRetranscribe: onRetranscribe
                )
            case .retranscribe(let item):
                RetranscribeView(
                    item: store.item(with: item.id) ?? item,
                    mode: $retranscribeMode,
                    target: $retranscribeTarget,
                    busy: retranscribeBusy,
                    note: retranscribeNote,
                    result: retranscribeResult,
                    onStart: { chosenMode, chosenTarget in
                        onStartRetranscribe(item, chosenMode, chosenTarget)
                    }
                )
            }
        }
    }
}

// MARK: - Exclamation-mark note: model, elapsed time, language direction

struct ItemInfoView: View {
    let item: RecordingItem
    let onRetranscribe: (RecordingItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let meta = item.transcription {
                        infoCard(meta)
                    } else {
                        Text("这条录音还没有转写记录，点下方按钮开始。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    transcriptCard
                    aiCard
                    Button {
                        onRetranscribe(item)
                    } label: {
                        Label("重新转写（可换模型与语言）", systemImage: "arrow.clockwise.circle.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("备注详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("返回") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                Text("备注 · 转写信息").font(.title3.bold())
            }
            Text(item.name).font(.subheadline.bold())
            Text("文件：\(item.fileName)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Text("来源：\(item.source.sectionTitle)　时长：\(String(format: "%.1f", item.duration)) 秒")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("当前转写内容", systemImage: "text.bubble.fill")
                .font(.subheadline.bold())
            Text(item.transcript ?? "（暂无转写内容）")
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("端侧模型分析", systemImage: "waveform.path.ecg")
                .font(.headline)
            if let analysis = item.voiceTimeline {
                VoiceTimelineView(analysis: analysis, duration: item.duration)
                Divider()
                infoRow("语音段", "\(analysis.segments.count) 段（Silero VAD）")
                infoRow("判定为我", "\(analysis.segments.filter(\.isMe).count) 段（CAMPPlus）")
                infoRow("声纹维度", "\(analysis.speakerDimension) 维")
            } else {
                Text("尚无 VAD / 声纹分析")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Divider()
            infoRow("SenseVoice", (item.senseVoiceText?.isEmpty == false) ? (item.senseVoiceText ?? "") : "未识别")
            infoRow("识别语言", item.senseVoiceLanguage ?? "—")
            Divider()
            infoRow("文本向量", item.searchVector == nil ? "未生成" : "EmbeddingGemma \(item.searchVector?.count ?? 0) 维")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func infoCard(_ meta: TranscriptionMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("本次转写记录", systemImage: "cpu")
                .font(.headline)
            infoRow("使用模型", meta.modelName)
            infoRow("识别模式", meta.modeTitle)
            infoRow("转写用时", meta.elapsedTitle)
            Divider()
            infoRow("模型检测语言", meta.sourceLanguage)
            infoRow("本次指定语言", meta.targetLanguage)
            infoRow("语言核对", meta.languageAgreement)
            infoRow("识别依据", meta.direction)
            infoRow("任务类型", meta.taskTitle)
            Divider()
            Text("选错语言只会让转写文本变差，不会改动原音频；重新转写时重选语言再跑一次即可。")
                .font(.caption2)
                .foregroundColor(.orange)
            Divider()
            infoRow("重新转写次数", "\(meta.retranscribeCount) 次")
            infoRow("完成时间", Self.timeString(meta.finishedAt))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption.bold())
            Spacer(minLength: 0)
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Retranscribe: mode + per-model target language catalog

struct RetranscribeView: View {
    let item: RecordingItem
    @Binding var mode: TranscriptionMode
    @Binding var target: TranscriptionTarget
    let busy: Bool
    let note: String
    let result: TranscriptionMeta?
    let onStart: (TranscriptionMode, TranscriptionTarget) -> Void
    @Environment(\.dismiss) private var dismiss

    private var options: [TranscriptionTarget] { LanguageCatalog.targets(for: mode) }
    private var effectiveTarget: TranscriptionTarget { LanguageCatalog.validated(target, for: mode) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    currentCard
                    modeSection
                    languageSection
                    previewSection
                    if let meta = result {
                        resultCard(meta)
                    }
                    actionSection
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("重新转写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("返回") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundColor(.blue)
                Text("重新转写").font(.title3.bold())
            }
            Text("\(item.name) · \(item.fileName)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Text("切换模式会整体替换可选识别语言，因为两个模型支持的语言不同。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("上次选错语言？在这里重选一次再重新转写即可，原音频不变。")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("上一次转写", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.bold())
            if let meta = item.transcription {
                Text("模型：\(meta.modelName)").font(.caption)
                Text("用时：\(meta.elapsedTitle)").font(.caption)
                Text("语言：\(meta.direction)").font(.caption)
                Text("任务：\(meta.taskTitle)").font(.caption)
            } else {
                Text("（暂无转写记录）").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1 · 选择识别模式").font(.subheadline.bold())
            Picker("识别模式", selection: Binding(
                get: { mode },
                set: { newMode in
                    mode = newMode
                    target = LanguageCatalog.defaultTarget(for: newMode)
                }
            )) {
                ForEach(TranscriptionMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Text("模型：\(mode.modelTitle) · Models/\(mode.folderName)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2 · 选择识别语言").font(.subheadline.bold())
            Picker("识别语言", selection: Binding(
                get: { effectiveTarget },
                set: { newTarget in target = newTarget }
            )) {
                ForEach(options) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            Text(LanguageCatalog.countLabel(for: mode))
                .font(.caption.bold())
                .foregroundColor(.blue)
            Text("当前：\(effectiveTarget.title) · \(effectiveTarget.detail)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Whisper 会把这段录音当作所选语言来转写，输出同语种文本；不是翻译。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("选错语言结果会变差：重新选一次再点「开始重新转写」即可，原音频不变。")
                .font(.caption2)
                .foregroundColor(.orange)
            Text("语言种类按模型区分：普通 Whisper Base 99 种（不含粤语），精准 Turbo 100 种（含粤语）。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("该模型可选识别语言 · 共 \(options.count) 项").font(.subheadline.bold())
            let shown = Array(options.prefix(12))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(shown) { option in
                    Text(option.title)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(
                            option.id == effectiveTarget.id
                                ? Color.blue.opacity(0.22)
                                : Color.gray.opacity(0.13)
                        ))
                }
            }
            if options.count > shown.count {
                Text("…另有 \(options.count - shown.count) 种，可在上方选择器滚动查看")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func resultCard(_ meta: TranscriptionMeta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("重新转写完成", systemImage: "checkmark.circle.fill")
                .font(.subheadline.bold())
                .foregroundColor(.green)
            Text("模型：\(meta.modelName)").font(.caption.bold())
            Text("用时：\(meta.elapsedTitle)").font(.caption)
            Text("语言：\(meta.direction)").font(.caption)
            Text("任务：\(meta.taskTitle)").font(.caption)
            Text("新结果：\(item.transcript ?? "（空）")")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.10)))
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onStart(mode, effectiveTarget)
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView() }
                    Text(busy ? "正在重新转写…" : "开始重新转写")
                        .font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            if !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Single result detail

struct ResultDetailView: View {
    let item: RecordingItem
    var isDemo: Bool = false
    @ObservedObject var store: RecordingStore
    let onInfo: (RecordingItem) -> Void
    let onRetranscribe: (RecordingItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundColor(.red)
                            Text(item.name).font(.title3.bold())
                        }
                        Text("文件：\(item.fileName)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                        Text("来源：\(item.source.sectionTitle)　时长：\(String(format: "%.1f", item.duration)) 秒")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let meta = item.transcription {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("转写记录", systemImage: "cpu")
                                .font(.subheadline.bold())
                            Text("模型：\(meta.modelName)").font(.caption.bold())
                            Text("用时：\(meta.elapsedTitle)").font(.caption)
                            Text("语言：\(meta.direction)").font(.caption)
                            Text("任务：\(meta.taskTitle) · 已重转 \(meta.retranscribeCount) 次")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
                    }

                    HStack(spacing: 12) {
                        Button { onInfo(item) } label: {
                            Label("备注详情", systemImage: "exclamationmark.circle.fill")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        Button { onRetranscribe(item) } label: {
                            Label("重新转写", systemImage: "arrow.clockwise.circle.fill")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("录音波形").font(.subheadline.bold()).foregroundColor(.secondary)
                        WaveformView(samples: item.waveform, color: .red, height: 56, barCount: 48)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("转写内容", systemImage: "text.bubble.fill")
                                .font(.subheadline.bold())
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        }
                        Text(item.transcript ?? "（暂无转写内容）")
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                    }

                    if isDemo {
                        HStack {
                            ProgressView()
                            Text("演示自动翻页中…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("转写详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("返回") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Session detail: ALL hold-to-talk clips of one conversation

struct SessionDetailView: View {
    let session: RecordingSession
    let items: [RecordingItem]
    var isDemo: Bool = false
    @ObservedObject var store: RecordingStore
    let onInfo: (RecordingItem) -> Void
    let onRetranscribe: (RecordingItem) -> Void
    @Environment(\.dismiss) private var dismiss

    private var totalDuration: Double {
        var total: Double = 0
        for item in items {
            total += item.duration
        }
        return total
    }

    private var fullTranscript: String {
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            let text = item.transcript ?? "（暂无转写）"
            lines.append("\(index + 1). \(text)")
        }
        return lines.joined(separator: "\n")
    }

    private var mergedWaveform: [Double] {
        WaveformExtractor.merged(items, bars: 48)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .foregroundColor(.green)
                            Text(session.title).font(.title3.bold())
                            Spacer()
                            Text(session.isArchived ? "已归档" : "进行中")
                                .font(.caption.bold())
                                .foregroundColor(session.isArchived ? .green : .orange)
                        }
                        Text("本会话共 \(items.count) 段按住说话录音 · 总时长 \(String(format: "%.1f", totalDuration)) 秒")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("全部说话录音均保存在本地，按说话顺序排列")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Merged waveform of the whole conversation
                    VStack(alignment: .leading, spacing: 8) {
                        Text("会话整体波形").font(.subheadline.bold()).foregroundColor(.secondary)
                        WaveformView(samples: mergedWaveform, color: .blue, height: 44, barCount: 48)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                    }

                    // Every clip of this session
                    Text("本会话全部说话录音").font(.subheadline.bold())
                    ForEach(items.indices, id: \.self) { index in
                        let clip = items[index]
                        let fresh = store.item(with: clip.id) ?? clip
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack {
                                Text("第 \(index + 1) 段 · \(clip.name)")
                                    .font(.caption.bold())
                                    .foregroundColor(.secondary)
                                if let code = clip.holdLanguageCode {
                                    Text(LanguageCatalog.shortName(for: code))
                                        .font(.caption2.bold())
                                        .foregroundColor(LanguageCatalog.tint(for: code))
                                }
                                Spacer()
                            }
                            HStack {
                                Spacer(minLength: 44)
                                VStack(alignment: .trailing, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "mic.fill")
                                            .font(.caption)
                                            .foregroundColor(.white)
                                        WaveformView(samples: clip.waveform, color: .white.opacity(0.9), height: 22, barCount: 24)
                                            .frame(width: 110)
                                        Text(String(format: "%.1fs", clip.duration))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundColor(.white.opacity(0.85))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(RoundedRectangle(cornerRadius: 16).fill(LanguageCatalog.tint(for: clip.holdLanguageCode).opacity(0.92)))
                                    Text("文件：\(fresh.fileName)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(fresh.transcript ?? "（暂无转写）")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
                            ItemMetaRow(
                                item: fresh,
                                onInfo: { onInfo(fresh) },
                                onRetranscribe: { onRetranscribe(fresh) }
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).stroke(LanguageCatalog.tint(for: clip.holdLanguageCode).opacity(0.35), lineWidth: 1))
                    }

                    // Combined transcript
                    VStack(alignment: .leading, spacing: 8) {
                        Label("会话全文", systemImage: "text.bubble.fill")
                            .font(.subheadline.bold())
                        Text(fullTranscript.isEmpty ? "（暂无转写内容）" : fullTranscript)
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                    }

                    if isDemo {
                        HStack {
                            ProgressView()
                            Text("演示自动翻页中…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("会话详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("返回") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Waveform

struct WaveformView: View {
    let samples: [Double]
    var color: Color = .blue
    var height: CGFloat = 28
    var barCount: Int = 32

    private var displayed: [Double] {
        guard samples.count > barCount else { return samples }
        let step = Double(samples.count) / Double(barCount)
        return (0..<barCount).map { i in
            samples[Swift.min(samples.count - 1, Int(Double(i) * step))]
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(displayed.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: Swift.max(3, displayed[i] * height))
            }
        }
        .frame(height: height)
    }
}
