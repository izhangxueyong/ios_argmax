//  AutoTranscribe - on-device speech recognition demo
//  Two bundled WhisperKit models (whisper-base / large-v3-turbo) plus
//  SenseVoiceSmall int8, Silero VAD int8, CAMPPlus and EmbeddingGemma Q8_0.
//  Recording list, VAD timeline, per-segment speaker tags, session archive,
//  per-item model notes and EmbeddingGemma semantic search.
//  No model is downloaded at runtime.

import SwiftUI

@main
struct AutoTranscribeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
