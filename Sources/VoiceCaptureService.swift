import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class VoiceCaptureService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published var transcript = ""
    @Published var errorMessage: String?
    @Published private(set) var audioFileName: String?
    @Published private(set) var speechAvailable = true

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var tapInstalled = false

    func toggle(localeIdentifier: String? = nil) async {
        if isRecording { stop() } else { await start(localeIdentifier: localeIdentifier) }
    }

    func start(localeIdentifier: String? = nil) async {
        errorMessage = nil
        transcript = ""
        audioFileName = nil

        let microphoneAllowed = await requestMicrophonePermission()
        guard microphoneAllowed else {
            errorMessage = String(localized: "Microphone access is required to record a thought.")
            return
        }
        let speechStatus = await requestSpeechPermission()
        speechAvailable = speechStatus == .authorized

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement,
                                    options: [.duckOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let fileName = "voice-\(UUID().uuidString).caf"
            let url = try voiceDirectory().appendingPathComponent(fileName)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            audioFile = file
            audioFileName = fileName

            var request: SFSpeechAudioBufferRecognitionRequest?
            if speechAvailable {
                let localeID = localeIdentifier ?? (Locale.current.language.languageCode?.identifier == "ar"
                    ? "ar-SA" : Locale.current.identifier)
                let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
                if let recognizer, recognizer.isAvailable {
                    let speechRequest = SFSpeechAudioBufferRecognitionRequest()
                    speechRequest.shouldReportPartialResults = true
                    if recognizer.supportsOnDeviceRecognition {
                        speechRequest.requiresOnDeviceRecognition = true
                    }
                    recognitionRequest = speechRequest
                    request = speechRequest
                    recognitionTask = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
                        Task { @MainActor in
                            if let result {
                                self?.transcript = result.bestTranscription.formattedString
                            }
                            if error != nil, self?.transcript.isEmpty == true {
                                self?.speechAvailable = false
                            }
                        }
                    }
                } else {
                    speechAvailable = false
                }
            }

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                try? file.write(from: buffer)
                request?.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            if !speechAvailable {
                errorMessage = String(localized: "Recording audio only; speech recognition is unavailable.")
            }
        } catch {
            cleanupAudio()
            errorMessage = String(format: String(localized: "Couldn't start recording: %@"),
                                  error.localizedDescription)
        }
    }

    func stop() {
        guard isRecording else { return }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    func discardRecording() {
        stop()
        guard let audioFileName,
              let url = try? voiceDirectory().appendingPathComponent(audioFileName) else { return }
        try? FileManager.default.removeItem(at: url)
        self.audioFileName = nil
    }

    static func audioURL(fileName: String) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent("VoiceNotes", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private func cleanupAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioFile = nil
        isRecording = false
    }

    private func voiceDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let directory = docs.appendingPathComponent("VoiceNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        return directory
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

@MainActor
final class VoiceNotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(fileName: String) {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        guard let url = VoiceCaptureService.audioURL(fileName: fileName),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.delegate = self
        player.play()
        isPlaying = true
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                 successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
