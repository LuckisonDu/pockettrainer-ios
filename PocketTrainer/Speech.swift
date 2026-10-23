// Speech.swift —— 「说话」输入：只用手机上的离线语音识别（SFSpeechRecognizer，requiresOnDeviceRecognition = true）。
// 声音不会离开手机；不支持离线识别的语言，按钮会变灰并说明原因。
import SwiftUI
import Speech
import AVFoundation

/// 当前界面语言对应的语音识别语言
func speechLocale() -> Locale {
    let map = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "es": "es-ES", "fr": "fr-FR", "en": "en-US"]
    let ui = Bundle.main.preferredLocalizations.first ?? "en"
    return Locale(identifier: map[ui] ?? "en-US")
}

final class SpeechInput: ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    @Published var message = ""            // 给用户看的提示（不可用 / 没权限）
    private let recognizer = SFSpeechRecognizer(locale: speechLocale())
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// 这个语言能不能在手机上离线识别
    var supported: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func toggle() { listening ? stop() : start() }

    func start() {
        guard supported else { message = tr("Speech recognition is not available on this device for this language."); return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { self.message = tr("Allow speech recognition and the microphone in Settings to talk to the app."); return }
                AVAudioApplication.requestRecordPermission { ok in
                    DispatchQueue.main.async { if ok { self.begin() } else { self.message = tr("Allow speech recognition and the microphone in Settings to talk to the app.") } }
                }
            }
        }
    }

    private func begin() {
        message = ""; transcript = ""
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true          // 只在手机上识别，绝不联网
        req.shouldReportPartialResults = true
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { message = tr("Could not start the microphone."); return }
        listening = true
        task = recognizer?.recognitionTask(with: req) { result, error in
            DispatchQueue.main.async {
                if let r = result { self.transcript = r.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
    }

    func stop() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); task?.cancel(); request = nil; task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 麦克风按钮：说完的文字填进 text（追加在后面）
struct MicButton: View {
    @Binding var text: String
    @StateObject private var speech = SpeechInput()
    @State private var base = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                base = text
                speech.toggle()
            } label: {
                Label(speech.listening ? tr("Stop") : tr("Speak"), systemImage: speech.listening ? "stop.circle.fill" : "mic.fill")
                    .foregroundColor(speech.listening ? .red : .teal)
            }
            .buttonStyle(.bordered).disabled(!speech.supported)
            if !speech.supported { Text("Speech recognition is not available on this device for this language.").font(.caption).foregroundColor(.secondary) }
            else if speech.listening { Text("Listening… (on this phone only)").font(.caption).foregroundColor(.secondary) }
            if !speech.message.isEmpty { Text(speech.message).font(.caption).foregroundColor(.orange) }
        }
        .onChange(of: speech.transcript) { t in if !t.isEmpty { text = base.isEmpty ? t : base + " " + t } }
        .onDisappear { speech.stop() }
    }
}
