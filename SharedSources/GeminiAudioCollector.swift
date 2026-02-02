import Foundation

@available(macOS 14.0, *)
public class GeminiAudioCollector {
    private let apiKey: String
    // Reuse a single WebSocket session to avoid per-sentence handshake overhead
    private var webSocketTask: URLSessionWebSocketTask?
    private var didSendSetup: Bool = false
    private let session = URLSession.shared

    // Concurrent call protection
    private var isCollecting = false
    private let operationLock = NSLock()
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    deinit {
        closeConnection()
    }

    /// Explicitly close the WebSocket connection to free resources
    public func closeConnection() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        didSendSetup = false
    }
    
    public func collectAudioChunks(from text: String, onComplete: ((Result<Void, Error>) -> Void)? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Check for concurrent calls
                self.operationLock.lock()
                if self.isCollecting {
                    self.operationLock.unlock()
                    let error = GeminiAudioCollectorError.alreadyCollecting
                    onComplete?(.failure(error))
                    continuation.finish(throwing: error)
                    return
                }
                self.isCollecting = true
                self.operationLock.unlock()

                defer {
                    self.operationLock.lock()
                    self.isCollecting = false
                    self.operationLock.unlock()
                }

                do {
                    try await self.performCollection(text: text, continuation: continuation, onComplete: onComplete)
                } catch {
                    // Notify completion with failure and finish the stream
                    onComplete?(.failure(error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func performCollection(text: String, continuation: AsyncThrowingStream<Data, Error>.Continuation, onComplete: ((Result<Void, Error>) -> Void)? = nil) async throws {
        // Use URL without API key for security - key goes in header
        guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent") else {
            throw GeminiAudioCollectorError.invalidURL
        }

        // Always create a fresh connection to avoid stale socket issues
        // (Gemini WebSocket connections timeout after ~10 minutes of idle)
        closeConnection()

        // Create request with API key in header instead of URL
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let task = session.webSocketTask(with: request)
        task.resume()
        webSocketTask = task

        guard let webSocketTask else {
            throw GeminiAudioCollectorError.invalidURL
        }
        
        do {
            // Send setup message only once per socket
            if !didSendSetup {
                let setupMessage = """
                {
                    "setup": {
                        "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
                        "generation_config": {
                            "response_modalities": ["AUDIO"],
                            "speech_config": {
                                "voice_config": {
                                    "prebuilt_voice_config": {
                                        "voice_name": "Aoede"
                                    }
                                }
                            }
                        }
                    }
                }
                """
                try await webSocketTask.send(.string(setupMessage))

                // Wait for and validate setup confirmation
                let setupResponse = try await webSocketTask.receive()
                if !validateSetupResponse(setupResponse) {
                    closeConnection()
                    throw GeminiAudioCollectorError.setupFailed("Invalid setup response from server")
                }
                didSendSetup = true
            }
            
            // Send text for TTS for this turn
            let textMessage = """
            {
                "client_content": {
                    "turns": [
                        {
                            "role": "user",
                            "parts": [
                                {
                                    "text": "You must only speak the exact text provided. Do not add any introduction, explanation, commentary, or conclusion. Do not ask questions. Do not say anything before or after the text. Only speak these exact words: \(text)"
                                }
                            ]
                        }
                    ],
                    "turn_complete": true
                }
            }
            """
            try await webSocketTask.send(.string(textMessage))
            
            // Collect audio chunks and yield them immediately for this turn
            var isComplete = false
            while !isComplete {
                let message = try await webSocketTask.receive()
                
                switch message {
                case .string(let text):
                    if text.contains("\"done\":true") || text.contains("turn_complete") || text.contains("\"turnComplete\":true") {
                        isComplete = true
                    }
                case .data(let data):
                    do {
                        if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // Check for completion in JSON response
                            if let serverContent = jsonObject["serverContent"] as? [String: Any],
                               let turnComplete = serverContent["turnComplete"] as? Bool,
                               turnComplete {
                                isComplete = true
                            }

                            // Extract audio data and yield immediately
                            if let serverContent = jsonObject["serverContent"] as? [String: Any],
                               let modelTurn = serverContent["modelTurn"] as? [String: Any],
                               let parts = modelTurn["parts"] as? [[String: Any]] {

                                for part in parts {
                                    if let inlineData = part["inlineData"] as? [String: Any],
                                       let mimeType = inlineData["mimeType"] as? String,
                                       mimeType.starts(with: "audio/pcm"),
                                       let base64Data = inlineData["data"] as? String,
                                       let actualAudioData = Data(base64Encoded: base64Data) {
                                        continuation.yield(actualAudioData)
                                    }
                                }
                            }
                        }
                    } catch {
                        // Log JSON parsing errors for debugging
                        print("⚠️ Gemini JSON parse error (data length: \(data.count)): \(error.localizedDescription)")
                    }
                @unknown default:
                    break
                }
            }
            
            // Notify successful completion before finishing the stream
            onComplete?(.success(()))
            continuation.finish()
            
        } catch {
            // Close connection on error to prevent resource leaks
            closeConnection()
            throw GeminiAudioCollectorError.collectionError(error)
        }
    }

    /// Validate that the setup response from the server is valid
    private func validateSetupResponse(_ message: URLSessionWebSocketTask.Message) -> Bool {
        switch message {
        case .string(let text):
            // Check for setupComplete in the response
            if text.contains("setupComplete") || text.contains("setup_complete") {
                return true
            }
            // Also accept if we get a valid JSON response without error
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["error"] == nil {
                return true
            }
            return false
        case .data(let data):
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["error"] == nil {
                return true
            }
            return false
        @unknown default:
            return false
        }
    }
}

public enum GeminiAudioCollectorError: Error, LocalizedError {
    case invalidURL
    case collectionError(Error)
    case alreadyCollecting
    case setupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .collectionError(let error):
            return "Audio collection error: \(error.localizedDescription)"
        case .alreadyCollecting:
            return "Audio collection already in progress"
        case .setupFailed(let reason):
            return "WebSocket setup failed: \(reason)"
        }
    }
}
