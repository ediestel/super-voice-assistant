import Foundation
import Speech
import AVFoundation

// MARK: - Delegate Protocol

public protocol AppleSpeechTranscriberDelegate: AnyObject {
    func speechTranscriber(_ t: AppleSpeechTranscriber, didUpdateTranscription text: String, isFinal: Bool)
    func speechTranscriberDidStartListening(_ t: AppleSpeechTranscriber)
    func speechTranscriberDidStopListening(_ t: AppleSpeechTranscriber)
    func speechTranscriber(_ t: AppleSpeechTranscriber, didFailWithError error: Error)
}

// MARK: - Transcriber

/// Wraps Apple's SFSpeechRecognizer + AVAudioEngine for continuous live dictation.
/// Delegate callbacks are always dispatched to the main thread.
public final class AppleSpeechTranscriber {

    public weak var delegate: AppleSpeechTranscriberDelegate?

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    public private(set) var isListening = false

    // MARK: Init

    public init(locale: Locale = .current) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        speechRecognizer?.defaultTaskHint = .dictation
    }

    // MARK: Permissions

    /// Requests speech recognition authorization; completion called on main thread.
    public func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: Session Control

    public func startListening() throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }
        teardown() // cancel any existing session

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep recognition on-device when the locale model supports it: private
        // (no audio leaves the Mac) and not capped at the ~1 min server-session limit.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let final = result.isFinal
                DispatchQueue.main.async {
                    self.delegate?.speechTranscriber(self, didUpdateTranscription: text, isFinal: final)
                }
                if final { self.teardown() }
            }
            if let error {
                DispatchQueue.main.async {
                    self.delegate?.speechTranscriber(self, didFailWithError: error)
                }
                self.teardown()
            }
        }

        let inputNode = audioEngine.inputNode
        // Defensive: remove any tap left over from a rapid stop/start before re-adding,
        // since installing a second tap on the same bus throws.
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        DispatchQueue.main.async { self.delegate?.speechTranscriberDidStartListening(self) }
    }

    public func stopListening() { teardown() }

    // MARK: Private

    private func teardown() {
        let was = isListening
        audioEngine.stop()
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        if was {
            DispatchQueue.main.async { self.delegate?.speechTranscriberDidStopListening(self) }
        }
    }
}

// MARK: - Error

public enum AppleSpeechError: LocalizedError {
    case recognizerUnavailable

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer unavailable. Check your internet connection and ensure Speech Recognition is enabled in System Settings → Privacy & Security."
        }
    }
}
