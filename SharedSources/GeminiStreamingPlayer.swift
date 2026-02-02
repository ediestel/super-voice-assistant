import Foundation
import AVFoundation

@available(macOS 14.0, *)
public class GeminiStreamingPlayer {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchEffect = AVAudioUnitTimePitch()
    private let audioFormat: AVAudioFormat

    // Thread safety for playerNode operations
    private let playerNodeLock = NSLock()
    private var pendingBufferCount = 0
    private let pendingBufferLock = NSLock()

    // Buffer queue management - max 3 buffers ahead to prevent memory accumulation
    private let maxPendingBuffers = 3
    private var isStopping = false
    private let stoppingLock = NSLock()

    public init(playbackSpeed: Float = 1.2) {
        self.audioFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!

        // Setup audio processing chain (same as GeminiTTS)
        timePitchEffect.rate = playbackSpeed
        timePitchEffect.pitch = 0 // Keep pitch unchanged

        audioEngine.attach(playerNode)
        audioEngine.attach(timePitchEffect)
        audioEngine.connect(playerNode, to: timePitchEffect, format: audioFormat)
        audioEngine.connect(timePitchEffect, to: audioEngine.mainMixerNode, format: audioFormat)

        // Don't configure on init to avoid crashes, will configure when starting engine
    }

    deinit {
        stopAudioEngine()
    }

    /// Reset player state to free scheduled buffers (idempotent)
    public func reset() {
        stoppingLock.lock()
        let wasStopping = isStopping
        isStopping = true
        stoppingLock.unlock()

        // Only perform cleanup if not already stopping
        if !wasStopping {
            playerNodeLock.lock()
            if playerNode.isPlaying {
                playerNode.stop()
            }
            playerNode.reset()
            playerNodeLock.unlock()

            // Reset pending buffer count
            pendingBufferLock.lock()
            pendingBufferCount = 0
            pendingBufferLock.unlock()
        }

        stoppingLock.lock()
        isStopping = false
        stoppingLock.unlock()
    }

    private func configureOutputDevice() {
        let deviceManager = AudioDeviceManager.shared

        guard !deviceManager.useSystemDefaultOutput,
              let device = deviceManager.getCurrentOutputDevice(),
              let deviceID = deviceManager.getAudioDeviceID(for: device.uid) else {
            return
        }

        do {
            try audioEngine.outputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            // Failed to set output device - use default
        }
    }

    private func startAudioEngine() throws {
        // Reconfigure output device in case settings changed
        configureOutputDevice()

        if !audioEngine.isRunning {
            try audioEngine.start()
        }
    }

    public func stopAudioEngine() {
        stoppingLock.lock()
        let wasStopping = isStopping
        isStopping = true
        stoppingLock.unlock()

        if !wasStopping {
            playerNodeLock.lock()
            if playerNode.isPlaying {
                playerNode.stop()
            }
            playerNode.reset()  // Clear any scheduled buffers to free memory
            playerNodeLock.unlock()

            // Reset pending buffer count
            pendingBufferLock.lock()
            pendingBufferCount = 0
            pendingBufferLock.unlock()

            if audioEngine.isRunning {
                audioEngine.stop()
            }
        }

        stoppingLock.lock()
        isStopping = false
        stoppingLock.unlock()
    }

    /// Check if player is currently playing
    public var isPlaying: Bool {
        playerNodeLock.lock()
        defer { playerNodeLock.unlock() }
        return playerNode.isPlaying
    }

    public func playAudioStream(_ audioStream: AsyncThrowingStream<Data, Error>) async throws {
        try startAudioEngine()

        var isFirstChunk = true

        do {
            for try await audioChunk in audioStream {
                // Check for cancellation
                try Task.checkCancellation()

                // Check if we're stopping
                stoppingLock.lock()
                let stopping = isStopping
                stoppingLock.unlock()
                if stopping { break }

                // Wait if we have too many pending buffers (backpressure)
                try await waitForBufferSpace()

                // Convert raw PCM data to AVAudioPCMBuffer
                let buffer = try createPCMBuffer(from: audioChunk)

                // Track pending buffer
                pendingBufferLock.lock()
                pendingBufferCount += 1
                pendingBufferLock.unlock()

                playerNodeLock.lock()
                if isFirstChunk {
                    playerNode.play()
                    isFirstChunk = false
                }

                // Schedule buffer with completion handler for tracking
                // Use dataPlayedBack for more accurate timing
                playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.pendingBufferLock.lock()
                    self?.pendingBufferCount -= 1
                    self?.pendingBufferLock.unlock()
                }
                playerNodeLock.unlock()

                // Adaptive delay based on queue depth
                let currentPending = getCurrentPendingCount()
                if currentPending == 0 {
                    // Queue empty - schedule immediately
                } else if currentPending < maxPendingBuffers {
                    // Some room - minimal delay
                    try await Task.sleep(nanoseconds: 500_000) // 0.5ms
                } else {
                    // Queue full - wait longer
                    try await Task.sleep(nanoseconds: 2_000_000) // 2ms
                }
            }

            // Wait for all buffers to complete playback
            try await waitForBuffersToComplete()

            // Clean up after playback
            reset()

        } catch {
            reset()  // Clean up on error too
            throw GeminiStreamingPlayerError.playbackError(error)
        }
    }

    /// Wait until there's room in the buffer queue
    private func waitForBufferSpace() async throws {
        while getCurrentPendingCount() >= maxPendingBuffers {
            try Task.checkCancellation()

            stoppingLock.lock()
            let stopping = isStopping
            stoppingLock.unlock()
            if stopping { return }

            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    /// Get current pending buffer count (thread-safe)
    private func getCurrentPendingCount() -> Int {
        pendingBufferLock.lock()
        let count = pendingBufferCount
        pendingBufferLock.unlock()
        return count
    }

    /// Wait for all pending buffers to finish playing
    private func waitForBuffersToComplete() async throws {
        while true {
            let remaining = getCurrentPendingCount()

            if remaining <= 0 {
                break
            }

            // Check if we should abort waiting
            stoppingLock.lock()
            let stopping = isStopping
            stoppingLock.unlock()
            if stopping { break }

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms polling interval
        }
    }

    public func playText(_ text: String, audioCollector: GeminiAudioCollector, maxRetries: Int = 3) async throws {
        try startAudioEngine()

        // Split text into sentences and rejoin with line breaks for natural pauses
        let sentences = SmartSentenceSplitter.splitIntoSentences(text)

        // Join sentences with triple line breaks to encourage model to add longer pauses
        let formattedText = sentences.joined(separator: "\n\n\n")

        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                try await playTextAttempt(formattedText, audioCollector: audioCollector)
                return // Success
            } catch {
                lastError = error

                // Check if it's a network error worth retrying
                let nsError = error as NSError
                let isNetworkError = nsError.domain == NSURLErrorDomain ||
                    (error as? GeminiAudioCollectorError) != nil

                if isNetworkError && attempt < maxRetries {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                    reset() // Reset player state before retry
                } else {
                    throw error
                }
            }
        }

        // Should not reach here, but just in case
        if let error = lastError {
            throw error
        }
    }

    private func playTextAttempt(_ formattedText: String, audioCollector: GeminiAudioCollector) async throws {
        var isFirstChunk = true

        // Start collection for the formatted text (all at once)
        let audioStream = audioCollector.collectAudioChunks(from: formattedText)

        // Stream and play audio chunks as they arrive
        for try await chunk in audioStream {
            try Task.checkCancellation()

            // Check if we're stopping
            stoppingLock.lock()
            let stopping = isStopping
            stoppingLock.unlock()
            if stopping { break }

            // Wait if we have too many pending buffers
            try await waitForBufferSpace()

            let buffer = try createPCMBuffer(from: chunk)

            // Track pending buffer
            pendingBufferLock.lock()
            pendingBufferCount += 1
            pendingBufferLock.unlock()

            playerNodeLock.lock()
            if isFirstChunk {
                playerNode.play()
                isFirstChunk = false
            }

            // Schedule buffer with accurate completion callback
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.pendingBufferLock.lock()
                self?.pendingBufferCount -= 1
                self?.pendingBufferLock.unlock()
            }
            playerNodeLock.unlock()

            // Adaptive delay based on queue depth
            let currentPending = getCurrentPendingCount()
            if currentPending == 0 {
                // Queue empty - schedule immediately
            } else if currentPending < maxPendingBuffers {
                try await Task.sleep(nanoseconds: 500_000) // 0.5ms
            } else {
                try await Task.sleep(nanoseconds: 2_000_000) // 2ms
            }
        }

        // Wait for all buffers to complete playback
        try await waitForBuffersToComplete()

        // Clean up after playback
        reset()
    }

    private func createPCMBuffer(from audioData: Data) throws -> AVAudioPCMBuffer {
        let frameCount = audioData.count / 2 // 16-bit samples = 2 bytes per frame

        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: UInt32(frameCount)) else {
            throw GeminiStreamingPlayerError.bufferCreationFailed
        }

        buffer.frameLength = UInt32(frameCount)

        // Copy audio data into buffer
        audioData.withUnsafeBytes { bytes in
            let int16Pointer = bytes.bindMemory(to: Int16.self)
            let floatPointer = buffer.floatChannelData![0]

            // Convert Int16 samples to Float samples (normalized to -1.0 to 1.0)
            for i in 0..<frameCount {
                floatPointer[i] = Float(int16Pointer[i]) / Float(Int16.max)
            }
        }

        return buffer
    }
}

public enum GeminiStreamingPlayerError: Error, LocalizedError {
    case bufferCreationFailed
    case playbackError(Error)

    public var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .playbackError(let error):
            return "Playback error: \(error.localizedDescription)"
        }
    }
}
