import Foundation
import AVFoundation
import AppKit
import SharedModels
import CoreAudio

protocol GeminiAudioRecordingManagerDelegate: AnyObject {
    func audioLevelDidUpdate(db: Float)
    func transcriptionDidStart()
    func transcriptionDidComplete(text: String)
    func transcriptionDidFail(error: String)
    func recordingWasCancelled()
    func recordingWasSkippedDueToSilence()
}

class GeminiAudioRecordingManager: KeyboardEventDelegate {
    weak var delegate: GeminiAudioRecordingManagerDelegate?

    // Audio properties
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    private var audioBuffer: [Float] = []
    private let sampleRate: Double = 16000
    private let maxBufferSamples = 16000 * 300  // 5 minutes max to prevent memory explosion

    // Proper resampling via AVAudioConverter
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    // Engine lifecycle serialization
    private let engineQueue = DispatchQueue(label: "com.supervoice.gemini.audioengine")
    private var isEngineRunning = false

    // State management - uses centralized state machine
    private let stateManager = RecordingStateManager.shared
    private let keyboardHandler = KeyboardEventHandler.shared

    // Track if this manager is the active keyboard delegate
    private var isKeyboardDelegateActive = false

    // Gemini transcriber
    private let geminiTranscriber = GeminiAudioTranscriber()

    /// Public accessor for recording state (for AppDelegate checks)
    var isRecording: Bool {
        return stateManager.activeSource == .gemini && stateManager.isRecording
    }

    init() {
        setupAudioEngine()
        requestMicrophonePermission()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()
    }

    private func configureInputDevice() {
        let deviceManager = AudioDeviceManager.shared

        // Check if user selected a specific device - set it as system default temporarily
        if !deviceManager.useSystemDefaultInput,
           let selectedUID = deviceManager.selectedInputDeviceUID,
           let deviceID = deviceManager.getAudioDeviceID(for: selectedUID) {

            // Set as system default input device
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceIDValue = deviceID
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &deviceIDValue
            )

            if status == noErr {
                let deviceName = deviceManager.availableInputDevices.first { $0.uid == selectedUID }?.name ?? selectedUID
                print("✅ Set system default input to: \(deviceName)")
            } else {
                print("⚠️ Failed to set default input device (error: \(status))")
            }
        } else {
            print("✅ Using system default input device")
        }

        let format = inputNode.outputFormat(forBus: 0)
        print("   Format: \(format.sampleRate)Hz, \(format.channelCount) channels")
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("Microphone permission granted")
            } else {
                print("Microphone permission denied")
                DispatchQueue.main.async {
                    self.showPermissionAlert()
                }
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "Please grant microphone access in System Settings > Privacy & Security > Microphone"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Recording Control

    func toggleRecording() {
        // Check current state
        if stateManager.activeSource == .gemini && stateManager.isRecording {
            stopRecording()
        } else if stateManager.canStart(source: .gemini) {
            startRecording()
        } else {
            print("⚠️ Cannot toggle Gemini recording - state: \(stateManager.currentState)")
        }
    }

    func startRecording() {
        // Transition to starting state
        guard stateManager.transition(to: .starting, source: .gemini) else {
            print("❌ Cannot start Gemini recording - invalid state transition")
            return
        }

        audioBuffer.removeAll()

        // Serialize engine operations to prevent race conditions
        engineQueue.async { [weak self] in
            guard let self = self else { return }

            // Wait for any prior engine to fully stop
            if self.isEngineRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }

            DispatchQueue.main.async {
                self.setupAndStartEngine()
            }
        }
    }

    private func setupAndStartEngine() {
        // Create fresh audio engine to avoid state issues
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()

        // Set up keyboard handler for this recording session (escape to cancel only)
        keyboardHandler.delegate = self
        keyboardHandler.setMode(.recording)
        isKeyboardDelegateActive = true

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Set up proper resampling via AVAudioConverter
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        if let targetFormat = targetFormat, recordingFormat.sampleRate != sampleRate {
            audioConverter = AVAudioConverter(from: recordingFormat, to: targetFormat)
            print("✅ Gemini: Using AVAudioConverter for resampling \(recordingFormat.sampleRate)Hz → \(sampleRate)Hz")
        } else {
            audioConverter = nil
            print("✅ Gemini: No resampling needed (native \(recordingFormat.sampleRate)Hz)")
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard self.stateManager.activeSource == .gemini && self.stateManager.isRecording else { return }

            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)

            if let channelData = channelData {
                var samples: [Float]

                // Resample to 16kHz using AVAudioConverter for accurate resampling
                if let converter = self.audioConverter, let targetFormat = self.targetFormat {
                    // Calculate output frame count based on sample rate ratio
                    let ratio = self.sampleRate / buffer.format.sampleRate
                    let outputFrameCount = UInt32(ceil(Double(frameLength) * ratio))

                    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
                        print("⚠️ Gemini: Failed to create output buffer")
                        return
                    }

                    var error: NSError?
                    var inputBufferConsumed = false
                    let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                        if inputBufferConsumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        inputBufferConsumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }

                    if status == .error, let error = error {
                        print("⚠️ Gemini: Converter error: \(error.localizedDescription)")
                        return
                    }

                    // Extract resampled samples
                    if let outputData = outputBuffer.floatChannelData?[0] {
                        samples = Array(UnsafeBufferPointer(start: outputData, count: Int(outputBuffer.frameLength)))
                    } else {
                        return
                    }
                } else {
                    // No resampling needed - use raw samples
                    samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                }

                self.audioBuffer.append(contentsOf: samples)

                // Prevent memory explosion from runaway recording
                if self.audioBuffer.count > self.maxBufferSamples {
                    print("⚠️ Audio buffer limit reached (5 min). Auto-stopping recording.")
                    DispatchQueue.main.async {
                        self.stopRecording()
                    }
                    return
                }

                // Calculate audio level from original buffer
                let rms = sqrt(channelData.withMemoryRebound(to: Float.self, capacity: frameLength) { ptr in
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += ptr[i] * ptr[i]
                    }
                    return sum / Float(frameLength)
                })

                let db = 20 * log10(max(rms, 0.00001))

                DispatchQueue.main.async {
                    self.delegate?.audioLevelDidUpdate(db: db)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isEngineRunning = true

            // Transition to recording state
            stateManager.transition(to: .recording, source: .gemini)
            print("🎤 Gemini audio recording started...")
        } catch {
            print("Failed to start audio engine: \(error)")
            stateManager.transition(to: .idle)
            cleanupKeyboardHandler()
            isEngineRunning = false
        }
    }

    func stopRecording() {
        guard stateManager.activeSource == .gemini && stateManager.isRecording else { return }

        // Transition to processing state
        stateManager.transition(to: .processing, source: .gemini)

        // Remove tap first before stopping engine
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isEngineRunning = false

        // Stop keyboard handler
        cleanupKeyboardHandler()

        print("⏹ Gemini recording stopped")
        print("Captured \(audioBuffer.count) audio samples")

        // Process the recording
        processRecording()
    }

    func cancelRecording() {
        // Remove tap first before stopping engine
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isEngineRunning = false
        audioBuffer.removeAll()

        // Stop keyboard handler
        cleanupKeyboardHandler()

        // Transition to idle
        stateManager.transition(to: .idle)

        print("Gemini recording cancelled")
        delegate?.recordingWasCancelled()
    }

    private func cleanupKeyboardHandler() {
        if isKeyboardDelegateActive {
            keyboardHandler.setMode(.inactive)
            if keyboardHandler.delegate === self {
                keyboardHandler.delegate = nil
            }
            isKeyboardDelegateActive = false
        }
    }

    private func processRecording() {
        guard !audioBuffer.isEmpty else {
            print("No audio recorded")
            delegate?.recordingWasSkippedDueToSilence()
            stateManager.transition(to: .idle)
            return
        }

        // Skip extremely short recordings to avoid spurious transcriptions
        let durationSeconds = Double(audioBuffer.count) / sampleRate
        let minDurationSeconds: Double = 0.30
        if durationSeconds < minDurationSeconds {
            print("Recording too short (\(String(format: "%.2f", durationSeconds))s). Skipping transcription.")
            delegate?.recordingWasSkippedDueToSilence()
            stateManager.transition(to: .idle)
            return
        }

        // Calculate RMS (Root Mean Square) to detect silence
        let rms = sqrt(audioBuffer.reduce(0) { $0 + $1 * $1 } / Float(audioBuffer.count))
        let db = 20 * log10(max(rms, 0.00001))

        // Threshold for silence detection
        let silenceThreshold: Float = -55.0

        if db < silenceThreshold {
            print("Audio too quiet (RMS: \(rms), dB: \(db)). Skipping transcription.")
            delegate?.recordingWasSkippedDueToSilence()
            stateManager.transition(to: .idle)
            return
        }

        // Start transcription
        delegate?.transcriptionDidStart()

        print("Sending audio to Gemini API for transcription (\(Double(audioBuffer.count) / sampleRate) seconds)...")

        // Send to Gemini API
        geminiTranscriber.transcribe(audioBuffer: audioBuffer) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                case .success(let transcription):
                    var trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // Apply text replacements from config
                        trimmed = TextReplacements.shared.processText(trimmed)

                        print("✅ Gemini transcription: \"\(trimmed)\"")

                        // Save to history
                        TranscriptionHistory.shared.addEntry(trimmed)

                        // Notify delegate
                        self.delegate?.transcriptionDidComplete(text: trimmed)
                    } else {
                        print("No transcription generated (possibly silence)")
                        self.delegate?.recordingWasSkippedDueToSilence()
                    }

                case .failure(let error):
                    print("Gemini transcription error: \(error.localizedDescription)")
                    self.delegate?.transcriptionDidFail(error: "Gemini transcription failed: \(error.localizedDescription)")
                }

                // Transition back to idle
                self.stateManager.transition(to: .idle)
            }
        }
    }

    // MARK: - KeyboardEventDelegate

    func handleSpaceDoubleTap() {
        // Gemini uses single stop via toggle, but support double-tap too
        stopRecording()
    }

    func handleEscapeKey() {
        cancelRecording()
    }

    func handleSpaceContinue() {
        // Gemini doesn't use continue mode, but implement for protocol conformance
    }

    func handleEscapeContinue() {
        // Gemini doesn't use continue mode, but implement for protocol conformance
    }
}
