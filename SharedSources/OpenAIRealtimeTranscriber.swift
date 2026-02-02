import Foundation
import os.log

/// Real-time transcription using OpenAI's Realtime API (WebSocket-based)
/// Streams audio and receives transcription deltas as you speak
@available(macOS 14.0, *)
public class OpenAIRealtimeTranscriber {

    private var webSocketTask: URLSessionWebSocketTask?

    // Phase 2.2: Configure URLSession with connection limits
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private var isSessionActive = false

    // Ping timer for connection health monitoring
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30

    // Backpressure handling
    private var pendingSendCount = 0
    private let pendingSendLock = NSLock()
    private let maxPendingSends = 100

    public var onTranscriptDelta: ((String) -> Void)?
    public var onFinalTranscript: ((String) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onSessionStarted: (() -> Void)?
    public var onSessionEnded: (() -> Void)?

    // Phase 2.4: Use NSTemporaryDirectory instead of hardcoded /tmp
    private let debugLogPath = NSTemporaryDirectory() + "openai_debug.log"

    // Phase 3.4: Structured logging with os_log
    private let logger = Logger(subsystem: "com.supervoice.openai", category: "streaming")

    /// File-based debug logging is disabled by default to prevent disk space exhaustion.
    /// Set OPENAI_DEBUG=1 environment variable to enable file logging.
    private var debugEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENAI_DEBUG"] != nil
    }

    public init() {}

    private func debugLog(_ message: String) {
        // Phase 3.4: Structured logging with os_log
        logger.debug("\(message, privacy: .public)")

        // Also print to console for visibility
        print(message)

        // Only write to file when explicitly enabled via environment variable
        guard debugEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugLogPath) {
                if let handle = FileHandle(forWritingAtPath: debugLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? logLine.write(toFile: debugLogPath, atomically: true, encoding: .utf8)
            }
        }
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Connection Management

    /// Phase 1.3: Network retry with exponential backoff
    public func connect(maxAttempts: Int = 3) async throws {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await performConnect()
                return
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delay = Double(1 << (attempt - 1)) // 1s, 2s, 4s exponential backoff
                    debugLog("⏳ Connection attempt \(attempt)/\(maxAttempts) failed, retrying in \(delay)s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? OpenAIRealtimeError.connectionFailed
    }

    private func performConnect() async throws {
        debugLog("🔑 Attempting to load OpenAI API key...")
        guard let apiKey = loadApiKey() else {
            debugLog("❌ OPENAI_API_KEY not found!")
            throw OpenAIRealtimeError.apiKeyNotFound
        }
        debugLog("🔑 API key loaded (length: \(apiKey.count))")

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw OpenAIRealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        debugLog("🔌 Connecting to OpenAI Realtime API...")
        let task = session.webSocketTask(with: request)
        task.resume()
        webSocketTask = task

        isSessionActive = true
        startReceiving()
        startPingTimer()

        debugLog("📡 Configuring session...")
        try await configureSession()
        onSessionStarted?()

        debugLog("✅ OpenAI Realtime transcription connection established")
    }
    
    public func disconnect() {
        cleanup()
        onSessionEnded?()
        print("🔌 OpenAI Realtime disconnected")
    }

    /// Phase 2.5: Cleanup method to ensure bounded resource usage
    private func cleanup() {
        stopPingTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isSessionActive = false

        // Reset backpressure counter
        pendingSendLock.lock()
        pendingSendCount = 0
        pendingSendLock.unlock()
    }

    // MARK: - Ping/Pong for Connection Health

    private func startPingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        guard let webSocketTask, isSessionActive else { return }
        webSocketTask.sendPing { [weak self] error in
            if let error = error {
                self?.debugLog("⚠️ Ping failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Session Configuration
    
    private func configureSession() async throws {
        guard let webSocketTask else {
            throw OpenAIRealtimeError.notConnected
        }

        // Configuration for transcription API (using ?intent=transcription URL)
        // Uses transcription_session.update instead of session.update
        let sessionConfig: [String: Any] = [
            "type": "transcription_session.update",
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "gpt-4o-transcribe"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.25,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ],
                "input_audio_noise_reduction": [
                    "type": "near_field"
                ]
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: sessionConfig)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        
        try await webSocketTask.send(.string(jsonString))
        print("📤 Sent session.update (transcription mode configured)")
    }
    
    // MARK: - Audio Streaming
    
    /// Send audio chunk (must be 16-bit PCM, 24kHz, mono, little-endian)
    public func sendAudioChunk(_ audioData: Data) async throws {
        guard let webSocketTask, isSessionActive else {
            throw OpenAIRealtimeError.notConnected
        }

        // Backpressure: check if we have too many pending sends
        pendingSendLock.lock()
        let currentPending = pendingSendCount
        pendingSendLock.unlock()

        if currentPending >= maxPendingSends {
            debugLog("⚠️ Backpressure: dropping audio chunk (\(currentPending) pending)")
            return
        }

        let base64Audio = audioData.base64EncodedString()

        let audioEvent: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: audioEvent)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Track pending send
        pendingSendLock.lock()
        pendingSendCount += 1
        pendingSendLock.unlock()

        do {
            try await webSocketTask.send(.string(jsonString))
        } catch {
            pendingSendLock.lock()
            pendingSendCount -= 1
            pendingSendLock.unlock()
            throw error
        }

        pendingSendLock.lock()
        pendingSendCount -= 1
        pendingSendLock.unlock()
        // NOTE: Per-chunk logging removed to prevent disk space exhaustion
        // (was logging ~100 chunks/second during recording)
    }
    
    // MARK: - Manual control (usually NOT needed with server_vad)
    
    /// Only needed if you switch turn_detection to null
    public func commitAudioBuffer() async throws {
        guard let webSocketTask, isSessionActive else {
            throw OpenAIRealtimeError.notConnected
        }
        
        let commitEvent: [String: String] = ["type": "input_audio_buffer.commit"]
        let jsonData = try JSONSerialization.data(withJSONObject: commitEvent)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        
        try await webSocketTask.send(.string(jsonString))
        print("📤 Manually committed audio buffer")
    }
    
    // MARK: - Message Receiving
    
    private func startReceiving() {
        Task { [weak self] in
            guard let self else { return }
            while let webSocketTask, isSessionActive {
                do {
                    let message = try await webSocketTask.receive()
                    handleMessage(message)
                } catch {
                    if isSessionActive {
                        print("❌ WebSocket receive error: \(error)")
                        DispatchQueue.main.async {
                            self.onError?(error)
                        }
                    }
                    break
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseEvent(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseEvent(text)
            }
        @unknown default:
            break
        }
    }
    
    /// Phase 2.3: Validate and parse WebSocket messages
    private func validateAndParseEvent(_ jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let _ = json["type"] as? String else {
            throw OpenAIRealtimeError.invalidMessage("Malformed event: \(jsonString.prefix(100))")
        }
        return json
    }

    private func parseEvent(_ jsonString: String) {
        let json: [String: Any]
        do {
            json = try validateAndParseEvent(jsonString)
        } catch {
            print("⚠️ Could not parse event: \(jsonString.prefix(120))…")
            return
        }

        guard let eventType = json["type"] as? String else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            self.debugLog("📥 Received event: \(eventType)")

            switch eventType {
            case "session.created", "session.updated":
                self.debugLog("📥 \(eventType)")
                
            case "input_audio_buffer.speech_started":
                self.debugLog("🎤 Speech started")

            case "input_audio_buffer.speech_stopped":
                self.debugLog("🎤 Speech stopped")

            case "input_audio_buffer.committed":
                if let itemId = json["item_id"] as? String {
                    self.debugLog("📦 Audio committed: item \(itemId)")
                }
                
            case "conversation.item.input_audio_transcription.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    self.debugLog("📝 Delta: \"\(delta)\"")
                    self.onTranscriptDelta?(delta)
                } else {
                    self.debugLog("⚠️ Delta event but no text: \(jsonString.prefix(200))")
                }

            case "conversation.item.input_audio_transcription.completed":
                self.debugLog("📥 COMPLETED EVENT: \(jsonString.prefix(500))")
                if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                    self.debugLog("✅ Final transcription: \"\(transcript)\"")
                    self.onFinalTranscript?(transcript)
                } else {
                    self.debugLog("⚠️ Completed event but no transcript")
                }
                
            case "error":
                if let errorInfo = json["error"] as? [String: Any],
                   let message = errorInfo["message"] as? String {
                    let code = errorInfo["code"] as? String ?? "unknown"
                    self.debugLog("❌ API Error [\(code)]: \(message)")
                    self.onError?(OpenAIRealtimeError.apiError(message))
                } else {
                    self.debugLog("❌ Unknown error: \(jsonString.prefix(500))")
                }
                
            default:
                // Log unhandled events for debugging
                print("📥 Event: \(eventType)")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func loadApiKey() -> String? {
        debugLog("🔑 Attempting to load OpenAI API key...")
        guard let key = EnvironmentLoader.getApiKey("OPENAI_API_KEY") else {
            debugLog("❌ OPENAI_API_KEY not found!")
            return nil
        }
        debugLog("🔑 Found OPENAI_API_KEY")
        return validateApiKey(key)
    }

    /// Phase 3.5: Validate API key format
    private func validateApiKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // OpenAI API keys typically start with "sk-"
        if !trimmed.hasPrefix("sk-") {
            debugLog("⚠️ API key doesn't match expected format (sk-*)")
        }
        return trimmed
    }
}

public enum OpenAIRealtimeError: Error, LocalizedError {
    case apiKeyNotFound
    case invalidURL
    case notConnected
    case apiError(String)
    case connectionFailed
    case invalidMessage(String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:
            return "OPENAI_API_KEY not found in environment or .env file"
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .notConnected:
            return "Not connected to OpenAI Realtime API"
        case .apiError(let message):
            return "API error: \(message)"
        case .connectionFailed:
            return "Failed to connect after multiple attempts"
        case .invalidMessage(let details):
            return "Invalid WebSocket message: \(details)"
        }
    }
}