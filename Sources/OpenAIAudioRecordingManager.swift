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

class OpenAIAudioRecordingManager {
    weak var delegate: OpenAIAudioRecordingManagerDelegate?

    // Audio properties - SAME as Gemini
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    private let targetSampleRate: Double = 24000

    // Recording state - SAME as Gemini (simple bools)
    var isRecording = false
    private var isStartingRecording = false
    private var firstSpacePressTime: Date?  // Double-tap detection (800ms window)
    private var escapeKeyMonitor: Any?
    private var spaceBarContinueMonitor: Any?
    private var canContinueWithSpaceBar = false

    // OpenAI specific
    private var realtimeTranscriber: OpenAIRealtimeTranscriber?
    private var fullTranscription = ""

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

    // SAME pattern as Gemini
    func toggleRecording() {
        if isStartingRecording {
            return
        }

        isRecording.toggle()

        if isRecording {
            startRecording()
        } else {
            stopRecording()
        }
    }

    func startRecording() {
        isStartingRecording = true
        firstSpacePressTime = nil  // Reset double-tap detection
        fullTranscription = ""
        audioChunkCount = 0

        // Fresh audio engine - SAME as Gemini
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()

        // Keyboard monitor: Double-tap Space to stop, Escape to cancel
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return }

            if event.keyCode == 49 { // Space bar - double-tap to stop
                let now = Date()
                if let firstPress = self.firstSpacePressTime, now.timeIntervalSince(firstPress) < 0.8 {
                    // Second tap within 800ms - stop recording
                    self.firstSpacePressTime = nil
                    print("⏹ OpenAI recording stopped by double-tap Space")
                    DispatchQueue.main.async {
                        self.stopRecording()
                    }
                } else {
                    // First tap - just record the time
                    self.firstSpacePressTime = now
                    print("⏸ First Space tap (tap again within 800ms to stop)")
                }
            } else if event.keyCode == 53 { // Escape - cancel immediately
                print("🛑 OpenAI recording cancelled by Escape key")
                DispatchQueue.main.async {
                    self.cancelRecording()
                }
            }
        }

        // Connect to OpenAI and start streaming
        guard #available(macOS 14.0, *) else {
            print("⚠️ OpenAI Realtime requires macOS 14.0+")
            isRecording = false
            isStartingRecording = false
            return
        }

        realtimeTranscriber = OpenAIRealtimeTranscriber()

        realtimeTranscriber?.onTranscriptDelta = { [weak self] delta in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fullTranscription += delta
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
                    self.isRecording = false
                    self.isStartingRecording = false
                }
            }
        }
    }

    private func startAudioCapture() {
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 2400, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            // Audio level - SAME as Gemini
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

            // Send audio to OpenAI
            self.sendAudioToOpenAI(buffer: buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            print("🎤 OpenAI audio capture started")
            isStartingRecording = false
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            isRecording = false
            isStartingRecording = false
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

        // Log sample rate on first chunk
        if audioChunkCount == 0 {
            print("🎵 Input sample rate: \(inputSampleRate) Hz, target: \(targetSampleRate) Hz")
        }

        var int16Samples: [Int16] = []

        if inputSampleRate >= targetSampleRate {
            // Downsample: skip samples
            let resampleRatio = Int(inputSampleRate / targetSampleRate)
            int16Samples.reserveCapacity(frameLength / max(resampleRatio, 1))

            for i in stride(from: 0, to: frameLength, by: resampleRatio) {
                let sample = floatData[i]
                let clamped = max(-1.0, min(1.0, sample))
                int16Samples.append(Int16(clamped * Float(Int16.max)))
            }
        } else {
            // Input rate is lower than target - just convert without resampling
            // OpenAI API should handle various sample rates
            int16Samples.reserveCapacity(frameLength)

            for i in 0..<frameLength {
                let sample = floatData[i]
                let clamped = max(-1.0, min(1.0, sample))
                int16Samples.append(Int16(clamped * Float(Int16.max)))
            }
        }

        let data = int16Samples.withUnsafeBytes { Data($0) }

        if #available(macOS 14.0, *) {
            guard let transcriber = realtimeTranscriber else {
                print("❌ realtimeTranscriber is nil!")
                return
            }

            audioChunkCount += 1
            if audioChunkCount % 20 == 1 {
                print("📤 Sending audio chunk #\(audioChunkCount) (\(data.count) bytes)")
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
        guard isRecording else { return } // Prevent double-stop
        isRecording = false

        audioEngine.stop()
        inputNode.removeTap(onBus: 0)

        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }

        print("⏹ OpenAI recording stopped, committing audio buffer...")

        // Manually commit the audio buffer so server processes whatever we sent
        if #available(macOS 14.0, *) {
            Task {
                try? await realtimeTranscriber?.commitAudioBuffer()
                print("📦 Audio buffer committed manually")
            }
        }

        // Wait for transcription to arrive before disconnecting (max 3 seconds)
        let waitStart = Date()
        let maxWait: TimeInterval = 3.0

        func checkAndFinalize() {
            let transcription = self.fullTranscription
            let elapsed = Date().timeIntervalSince(waitStart)

            // If we have transcription OR timeout reached, finalize
            if !transcription.isEmpty || elapsed >= maxWait {
                if #available(macOS 14.0, *) {
                    self.realtimeTranscriber?.disconnect()
                    self.realtimeTranscriber = nil
                }

                DispatchQueue.main.async { [weak self] in
                    if !transcription.isEmpty {
                        let processed = TextReplacements.shared.processText(transcription)
                        print("✅ OpenAI transcription: \"\(processed)\"")
                        TranscriptionHistory.shared.addEntry(processed)
                        self?.delegate?.openAITranscriptionDidComplete(text: processed)
                        // Enable space bar to continue
                        self?.enableSpaceBarContinue()
                    } else {
                        print("No transcription generated (waited \(String(format: "%.1f", elapsed))s)")
                        self?.delegate?.openAIRecordingWasSkippedDueToSilence()
                    }
                }
            } else {
                // Keep waiting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkAndFinalize()
                }
            }
        }

        // Start checking after a brief delay for commit to send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            checkAndFinalize()
        }
    }

    func cancelRecording() {
        isRecording = false
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)

        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }

        if #available(macOS 14.0, *) {
            realtimeTranscriber?.disconnect()
            realtimeTranscriber = nil
        }

        fullTranscription = ""
        print("OpenAI recording cancelled")
        delegate?.openAIRecordingWasCancelled()
    }

    // MARK: - Space Bar Continue

    private func enableSpaceBarContinue() {
        canContinueWithSpaceBar = true
        print("⏎ Space=continue, Esc=done")

        // Remove any existing monitor
        if let monitor = spaceBarContinueMonitor {
            NSEvent.removeMonitor(monitor)
        }

        // Set up space bar monitor for continuing
        spaceBarContinueMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.canContinueWithSpaceBar, !self.isRecording else { return }

            if event.keyCode == 49 { // Space bar
                print("⏎ Continuing recording via Space bar")
                DispatchQueue.main.async {
                    self.disableSpaceBarContinue()
                    self.toggleRecording() // Start new recording
                }
            } else if event.keyCode == 53 { // Escape - cancel continue mode
                print("❌ Continue mode cancelled")
                DispatchQueue.main.async {
                    self.disableSpaceBarContinue()
                }
            }
        }

    }

    private func disableSpaceBarContinue() {
        canContinueWithSpaceBar = false
        if let monitor = spaceBarContinueMonitor {
            NSEvent.removeMonitor(monitor)
            spaceBarContinueMonitor = nil
        }
    }
}
