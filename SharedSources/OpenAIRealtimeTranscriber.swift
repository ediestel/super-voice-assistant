import Foundation

/// Real-time transcription using OpenAI's Realtime API (WebSocket-based)
/// Streams audio and receives transcription deltas as you speak
@available(macOS 14.0, *)
public class OpenAIRealtimeTranscriber {
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession.shared
    private var isSessionActive = false
    
    public var onTranscriptDelta: ((String) -> Void)?
    public var onFinalTranscript: ((String) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onSessionStarted: (() -> Void)?
    public var onSessionEnded: (() -> Void)?
    
    private let debugLogPath = "/tmp/openai_debug.log"

    /// File-based debug logging is disabled by default to prevent disk space exhaustion.
    /// Set OPENAI_DEBUG=1 environment variable to enable file logging.
    private var debugEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENAI_DEBUG"] != nil
    }

    public init() {}

    private func debugLog(_ message: String) {
        // Always print to console for visibility
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
    
    public func connect() async throws {
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

        debugLog("📡 Configuring session...")
        try await configureSession()
        onSessionStarted?()

        debugLog("✅ OpenAI Realtime transcription connection established")
    }
    
    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isSessionActive = false
        onSessionEnded?()
        print("🔌 OpenAI Realtime disconnected")
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
                    "threshold": 0.5,
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
        
        let base64Audio = audioData.base64EncodedString()
        
        let audioEvent: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: audioEvent)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        
        try await webSocketTask.send(.string(jsonString))
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
    
    private func parseEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            print("⚠️ Could not parse event: \(jsonString.prefix(120))…")
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            self.debugLog("📥 Received event: \(eventType)")

            switch eventType {
            case "session.created", "session.updated":
                self.debugLog("📥 \(eventType)")
                
            case "input_audio_buffer.speech_started":
                print("🎤 Speech started")
                
            case "input_audio_buffer.speech_stopped":
                print("🎤 Speech stopped")
                
            case "input_audio_buffer.committed":
                if let itemId = json["item_id"] as? String {
                    print("📦 Audio committed: item \(itemId)")
                }
                
            case "conversation.item.input_audio_transcription.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    self.debugLog("📝 Delta: \"\(delta)\"")
                    self.onTranscriptDelta?(delta)
                } else {
                    self.debugLog("⚠️ Delta event but no text: \(jsonString.prefix(200))")
                }

            case "conversation.item.input_audio_transcription.completed":
                if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                    self.debugLog("✅ Final transcription: \"\(transcript)\"")
                    self.onFinalTranscript?(transcript)
                } else {
                    self.debugLog("⚠️ Completed event but no transcript: \(jsonString.prefix(200))")
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
                // Log unknown events for debugging
                print("📥 Event: \(eventType) - \(jsonString.prefix(200))…")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func loadApiKey() -> String? {
        // 1. Environment variable
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
            debugLog("🔑 Found OPENAI_API_KEY in environment")
            return envKey
        }
        debugLog("⚠️ OPENAI_API_KEY not in environment, checking .env files...")

        // 2. Check multiple .env locations
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let envPaths = [
            homeDir + "/Desktop/Coding_Projects/super-voice-assistant/.env",
            homeDir + "/.env",
            FileManager.default.currentDirectoryPath + "/.env",
            ".env"
        ]

        for envPath in envPaths {
            debugLog("🔍 Checking: \(envPath)")
            if let key = loadKeyFromEnvFile(path: envPath) {
                return key
            }
        }

        debugLog("❌ OPENAI_API_KEY not found in any .env file")
        return nil
    }

    private func loadKeyFromEnvFile(path: String) -> String? {
        guard let envContent = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        for line in envContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("OPENAI_API_KEY=") {
                let key = String(trimmed.dropFirst("OPENAI_API_KEY=".count))
                if !key.isEmpty {
                    debugLog("🔑 Found OPENAI_API_KEY in \(path)")
                    return key
                }
            }
        }
        return nil
    }
}

public enum OpenAIRealtimeError: Error, LocalizedError {
    case apiKeyNotFound
    case invalidURL
    case notConnected
    case apiError(String)
    
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
        }
    }
}