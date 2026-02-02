import Foundation
import AVFoundation
import AppKit
import SharedModels
import CoreAudio

protocol OpenAIAudioRecordingManagerDelegate: AnyObject {
    func openAIAudioLevelDidUpdate(db: Float)
    func openAITranscriptionDidStart()
    func openAITranscriptionDidReceiveDelta(delta: String)
    func openAITranscriptionDidComplete(text: String)
    func openAITranscriptionDidFail(error: String)
    func openAIRecordingWasCancelled()
    func openAIRecordingWasSkippedDueToSilence()
}

class OpenAIAudioRecordingManager: KeyboardEventDelegate {
    weak var delegate: OpenAIAudioRecordingManagerDelegate?

    // Audio properties
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    private let targetSampleRate: Double = 24000

    // Proper resampling via AVAudioConverter
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    // Engine lifecycle serialization
    private let engineQueue = DispatchQueue(label: "com.supervoice.openai.audioengine")
    private var isEngineRunning = false

    // State management - uses centralized state machine
    private let stateManager = RecordingStateManager.shared
    private let keyboardHandler = KeyboardEventHandler.shared

    // OpenAI specific
    private var realtimeTranscriber: OpenAIRealtimeTranscriber?
    // Thread-safe delta collection
    private var transcriptionDeltas: [String] = []
    private let deltasLock = NSLock()

    // Track if this manager is the active keyboard delegate
    private var isKeyboardDelegateActive = false

    /// Public accessor for recording state (for AppDelegate checks)
    var isRecording: Bool {
        return stateManager.activeSource == .openai && stateManager.isRecording
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

        if !deviceManager.useSystemDefaultInput,
           let selectedUID = deviceManager.selectedInputDeviceUID,
           let deviceID = deviceManager.getAudioDeviceID(for: selectedUID) {

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
                print("✅ OpenAI: Set input to \(deviceName)")
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        print("✅ OpenAI: Format \(format.sampleRate)Hz, \(format.channelCount) ch")
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
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
        if stateManager.activeSource == .openai && stateManager.isRecording {
            stopRecording()
        } else if stateManager.canStart(source: .openai) {
            startRecording()
        } else {
            print("⚠️ Cannot toggle OpenAI recording - state: \(stateManager.currentState)")
        }
    }

    func startRecording() {
        // Transition to starting state
        guard stateManager.transition(to: .starting, source: .openai) else {
            print("❌ Cannot start OpenAI recording - invalid state transition")
            return
        }

        // Thread-safe clear of deltas
        deltasLock.lock()
        transcriptionDeltas.removeAll()
        deltasLock.unlock()

        audioChunkCount = 0

        // Serialize engine operations to prevent race conditions
        engineQueue.async { [weak self] in
            guard let self = self else { return }

            // Wait for any prior engine to fully stop
            if self.isEngineRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }

            DispatchQueue.main.async {
                self.setupAndConnectOpenAI()
            }
        }
    }

    private func setupAndConnectOpenAI() {
        // Fresh audio engine
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()

        // Set up keyboard handler for this recording session
        keyboardHandler.delegate = self
        keyboardHandler.setMode(.recording)
        isKeyboardDelegateActive = true

        // Connect to OpenAI and start streaming
        guard #available(macOS 14.0, *) else {
            print("⚠️ OpenAI Realtime requires macOS 14.0+")
            stateManager.transition(to: .idle)
            return
        }

        realtimeTranscriber = OpenAIRealtimeTranscriber()

        // Collect deltas in array instead of O(n²) string concatenation
        realtimeTranscriber?.onTranscriptDelta = { [weak self] delta in
            guard let self = self else { return }
            self.deltasLock.lock()
            self.transcriptionDeltas.append(delta)
            self.deltasLock.unlock()
            DispatchQueue.main.async {
                self.delegate?.openAITranscriptionDidReceiveDelta(delta: delta)
            }
        }

        realtimeTranscriber?.onError = { [weak self] error in
            print("❌ OpenAI error: \(error)")
            DispatchQueue.main.async {
                self?.delegate?.openAITranscriptionDidFail(error: error.localizedDescription)
            }
        }

        realtimeTranscriber?.onSessionStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.delegate?.openAITranscriptionDidStart()
            }
        }

        // Handle final transcript from server VAD
        realtimeTranscriber?.onFinalTranscript = { [weak self] finalText in
            print("📨 onFinalTranscript received: \"\(finalText.prefix(50))...\"")
            self?.handleTranscriptionComplete(finalText)
        }

        // Connect and start audio
        Task {
            do {
                try await realtimeTranscriber?.connect()
                await MainActor.run {
                    self.startAudioCapture()
                }
            } catch {
                print("❌ Failed to connect: \(error)")
                await MainActor.run {
                    self.delegate?.openAITranscriptionDidFail(error: error.localizedDescription)
                    self.stateManager.transition(to: .idle)
                    self.cleanupKeyboardHandler()
                }
            }
        }
    }

    private func startAudioCapture() {
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Set up proper resampling via AVAudioConverter
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)
        if let targetFormat = targetFormat, recordingFormat.sampleRate != targetSampleRate {
            audioConverter = AVAudioConverter(from: recordingFormat, to: targetFormat)
            print("✅ OpenAI: Using AVAudioConverter for resampling \(recordingFormat.sampleRate)Hz → \(targetSampleRate)Hz")
        } else {
            audioConverter = nil
            print("✅ OpenAI: No resampling needed (native \(recordingFormat.sampleRate)Hz)")
        }

        inputNode.installTap(onBus: 0, bufferSize: 2400, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, self.stateManager.activeSource == .openai && self.stateManager.isRecording else { return }

            // Audio level calculation
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrt(sum / Float(frameLength))
                let db = 20 * log10(max(rms, 0.00001))

                DispatchQueue.main.async {
                    self.delegate?.openAIAudioLevelDidUpdate(db: db)
                }
            }

            // Send audio to OpenAI (with proper resampling)
            self.sendAudioToOpenAI(buffer: buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isEngineRunning = true

            // Transition to recording state
            stateManager.transition(to: .recording, source: .openai)
            print("🎤 OpenAI audio capture started")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            stateManager.transition(to: .idle)
            cleanupKeyboardHandler()
            isEngineRunning = false
        }
    }

    private var audioChunkCount = 0

    private func sendAudioToOpenAI(buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else {
            print("❌ No float channel data")
            return
        }

        let frameLength = Int(buffer.frameLength)
        let inputSampleRate = buffer.format.sampleRate

        // Log format on first chunk
        if audioChunkCount == 0 {
            print("🎵 Input: \(Int(inputSampleRate))Hz \(buffer.format.channelCount)ch → \(Int(targetSampleRate))Hz mono")
        }

        var int16Samples: [Int16] = []

        // Manual conversion: take channel 0, downsample (e.g. 48kHz→24kHz = every 2nd sample)
        // AVAudioConverter doesn't handle multi-channel to mono conversion properly
        let decimationFactor = max(1, Int(inputSampleRate / targetSampleRate))
        let outputLength = frameLength / decimationFactor
        int16Samples.reserveCapacity(outputLength)

        for i in stride(from: 0, to: frameLength, by: decimationFactor) {
            let sample = floatData[i]
            let clamped = max(-1.0, min(1.0, sample))
            int16Samples.append(Int16(clamped * Float(Int16.max)))
        }

        let data = int16Samples.withUnsafeBytes { Data($0) }

        if #available(macOS 14.0, *) {
            guard let transcriber = realtimeTranscriber else {
                print("❌ realtimeTranscriber is nil!")
                return
            }

            audioChunkCount += 1
            // Log every 100 chunks (~10 seconds) to reduce noise
            if audioChunkCount == 1 || audioChunkCount % 100 == 0 {
                print("📤 Audio chunk #\(audioChunkCount)")
            }

            Task {
                do {
                    try await transcriber.sendAudioChunk(data)
                } catch {
                    print("❌ Failed to send audio chunk: \(error)")
                }
            }
        }
    }

    func stopRecording() {
        guard stateManager.activeSource == .openai && stateManager.isRecording else { return }

        // Transition to processing state
        stateManager.transition(to: .processing, source: .openai)

        // Remove tap first before stopping engine
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isEngineRunning = false

        // Stop keyboard handler for recording mode
        keyboardHandler.setMode(.inactive)

        print("⏹ OpenAI recording stopped, committing audio buffer...")

        // With server VAD, transcription is handled via onFinalTranscript callback (set in setupAndConnectOpenAI)
        // Timeout fallback in case VAD doesn't trigger
        if #available(macOS 14.0, *) {
            print("⏳ Waiting for final transcription...")

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                // Only trigger timeout if we haven't already processed
                if self.realtimeTranscriber != nil {
                    print("⏰ TIMEOUT - using collected deltas")
                    self.deltasLock.lock()
                    let transcription = self.transcriptionDeltas.joined()
                    self.deltasLock.unlock()
                    self.handleTranscriptionComplete(transcription)
                }
            }
        }
    }

    /// Handles transcription completion (called by final transcript callback or timeout)
    private func handleTranscriptionComplete(_ transcription: String) {
        // Prevent double-processing
        guard realtimeTranscriber != nil else { return }

        // Stop audio capture FIRST to prevent "realtimeTranscriber is nil" spam
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isEngineRunning = false

        // Transition to processing state
        stateManager.transition(to: .processing, source: .openai)

        if #available(macOS 14.0, *) {
            realtimeTranscriber?.disconnect()
            realtimeTranscriber = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if !transcription.isEmpty {
                let processed = TextReplacements.shared.processText(transcription)
                print("✅ OpenAI transcription: \"\(processed)\"")
                TranscriptionHistory.shared.addEntry(processed)
                self.delegate?.openAITranscriptionDidComplete(text: processed)
                // Enable continue mode
                self.enableContinueMode()
            } else {
                // Join deltas as fallback (thread-safe)
                self.deltasLock.lock()
                let fallback = self.transcriptionDeltas.joined()
                self.deltasLock.unlock()
                if !fallback.isEmpty {
                    let processed = TextReplacements.shared.processText(fallback)
                    print("✅ OpenAI transcription (from deltas): \"\(processed)\"")
                    TranscriptionHistory.shared.addEntry(processed)
                    self.delegate?.openAITranscriptionDidComplete(text: processed)
                    self.enableContinueMode()
                } else {
                    print("No transcription generated")
                    self.delegate?.openAIRecordingWasSkippedDueToSilence()
                    self.stateManager.transition(to: .idle)
                    self.cleanupKeyboardHandler()
                }
            }
        }
    }

    func cancelRecording() {
        // Remove tap first before stopping engine
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isEngineRunning = false

        // Stop keyboard handler
        cleanupKeyboardHandler()

        if #available(macOS 14.0, *) {
            realtimeTranscriber?.disconnect()
            realtimeTranscriber = nil
        }

        // Thread-safe clear
        deltasLock.lock()
        transcriptionDeltas.removeAll()
        deltasLock.unlock()

        // Transition to idle
        stateManager.transition(to: .idle)

        print("OpenAI recording cancelled")
        delegate?.openAIRecordingWasCancelled()
    }

    // MARK: - Continue Mode

    private func enableContinueMode() {
        stateManager.transition(to: .continueMode, source: .openai)
        print("⏎ Space=continue, Esc=done")

        // Set up keyboard handler for continue mode
        keyboardHandler.delegate = self
        keyboardHandler.setMode(.continueMode)
        isKeyboardDelegateActive = true
    }

    private func disableContinueMode() {
        stateManager.transition(to: .idle)
        cleanupKeyboardHandler()
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

    // MARK: - KeyboardEventDelegate

    func handleSpaceDoubleTap() {
        stopRecording()
    }

    func handleEscapeKey() {
        cancelRecording()
    }

    func handleSpaceContinue() {
        disableContinueMode()
        toggleRecording() // Start new recording
    }

    func handleEscapeContinue() {
        disableContinueMode()
    }
}
