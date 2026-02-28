import Foundation
import Speech
import AVFoundation

/// Simple speech-to-text service for iOS. Tap to record, tap again to send.
@Observable
final class SpeechService {
    var isListening = false
    var transcript = ""
    var isAuthorized = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var countdownTimer: Timer?

    /// Seconds remaining (60s Apple limit)
    var remainingTime: Double = 60
    var timerProgress: Double { max(0, remainingTime / 60.0) }

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.isAuthorized = (status == .authorized)
            }
        }
    }

    func startListening() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("[SpeechService] Recognizer not available")
            return
        }

        stopAudioEngine()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            self.audioEngine = engine

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                self.recognitionRequest?.append(buffer)
            }

            engine.prepare()
            try engine.start()

            isListening = true
            remainingTime = 60
            transcript = ""

            // 60s countdown (Apple Speech limit)
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.remainingTime -= 0.1
                    if self.remainingTime <= 0 {
                        self.stopListening()
                    }
                }
            }

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    // 1110 = no speech detected, ignore
                    if (error as NSError).code == 1110 { return }
                    print("[SpeechService] Recognition error: \(error.localizedDescription)")
                }
                if let result {
                    DispatchQueue.main.async {
                        self.transcript = result.bestTranscription.formattedString
                    }
                }
            }
        } catch {
            print("[SpeechService] Audio engine error: \(error)")
            stopListening()
        }
    }

    func stopListening() {
        stopAudioEngine()
        DispatchQueue.main.async {
            self.isListening = false
        }
    }

    /// Clear transcript after it's been sent
    func clearTranscript() {
        transcript = ""
    }

    private func stopAudioEngine() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
}
