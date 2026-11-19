//  AutoTranscribe - on-device speech recognition demo
//  Two bundled WhisperKit models (whisper-base / large-v3-turbo),
//  recording list, session archive and per-item model notes.
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
