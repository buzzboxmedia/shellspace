import Foundation
import Speech
import AVFoundation

/// Speech-to-text and text-to-speech service for conversational voice mode.
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    var isListening = false
    var transcript = ""
    var isAuthorized = false
    var isSpeaking = false
    var conversationMode = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var countdownTimer: Timer?
    private var synthesizer: AVSpeechSynthesizer?

    /// Called when TTS finishes speaking — used to auto-listen
    var onSpeakingFinished: (() -> Void)?

    /// Seconds remaining (60s Apple limit)
    var remainingTime: Double = 60
    var timerProgress: Double { max(0, remainingTime / 60.0) }

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        synthesizer = AVSpeechSynthesizer()
        synthesizer?.delegate = self
    }

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.isAuthorized = (status == .authorized)
            }
        }
    }

    // MARK: - Speech-to-Text

    func startListening() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("[SpeechService] Recognizer not available")
            return
        }

        // Stop any TTS first
        stopSpeaking()
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

    // MARK: - Text-to-Speech

    func speak(_ text: String) {
        stopAudioEngine()
        stopSpeaking()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("[SpeechService] TTS audio session error: \(error)")
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        isSpeaking = true
        synthesizer?.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer?.isSpeaking == true {
            synthesizer?.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    /// Stop everything — listening, speaking, conversation
    func stopAll() {
        conversationMode = false
        stopListening()
        stopSpeaking()
        clearTranscript()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.onSpeakingFinished?()
        }
    }

    // MARK: - Private

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
