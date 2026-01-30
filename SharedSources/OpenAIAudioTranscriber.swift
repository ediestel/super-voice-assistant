import Foundation
import AVFoundation

/// Transcribes audio using OpenAI's gpt-4o-transcribe model with true streaming deltas
public class OpenAIAudioTranscriber {
    
    public init() {}
    
    public enum TranscriptionError: Error, LocalizedError {
        case apiKeyNotFound
        case audioConversionFailed
        case requestFailed(statusCode: Int, message: String)
        case noTranscriptionInResponse
        
        public var errorDescription: String? {
            switch self {
            case .apiKeyNotFound:
                return "OPENAI_API_KEY not found in environment or .env file"
            case .audioConversionFailed:
                return "Failed to convert audio to WAV format"
            case .requestFailed(let statusCode, let message):
                return "API request failed (status \(statusCode)): \(message)"
            case .noTranscriptionInResponse:
                return "No transcription text in API response"
            }
        }
    }
    
    /// Transcribe audio buffer using OpenAI API with streaming
    /// - Parameters:
    ///   - audioBuffer: Float array of audio samples at 16kHz
    ///   - onDelta: Called for each text delta received (for real-time display)
    ///   - completion: Completion handler with final transcription result
    public func transcribe(
        audioBuffer: [Float],
        onDelta: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Load API key
        guard let apiKey = loadApiKey() else {
            completion(.failure(TranscriptionError.apiKeyNotFound))
            return
        }
        
        // Pad short audio with silence to improve reliability
        let sampleRate = 16000
        let minDurationSeconds: Float = 1.5
        let paddingDurationSeconds: Float = 1.0
        let minSamples = Int(minDurationSeconds * Float(sampleRate))
        let paddingSamples = Int(paddingDurationSeconds * Float(sampleRate))
        
        var paddedBuffer = audioBuffer
        if audioBuffer.count < minSamples {
            paddedBuffer.append(contentsOf: [Float](repeating: 0.0, count: paddingSamples))
        }
        
        // Convert to WAV data
        guard let wavData = convertToWAV(audioBuffer: paddedBuffer, sampleRate: sampleRate) else {
            completion(.failure(TranscriptionError.audioConversionFailed))
            return
        }
        
        // Build multipart form data
        let boundary = UUID().uuidString
        var body = Data()
        
        // Model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("gpt-4o-transcribe\r\n".data(using: .utf8)!)
        
        // Stream = true
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"stream\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)
        
        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        // Perform streaming request
        Task {
            do {
                let result = try await performStreamingRequest(request: request, onDelta: onDelta)
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func performStreamingRequest(request: URLRequest, onDelta: ((String) -> Void)?) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.requestFailed(statusCode: 0, message: "Invalid response")
        }
        
        if httpResponse.statusCode != 200 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.requestFailed(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse SSE stream
        var fullText = ""
        var lineBuffer = ""
        
        for try await byte in bytes {
            guard let char = String(data: Data([byte]), encoding: .utf8) else { continue }
            
            if char == "\n" {
                let line = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                lineBuffer = ""
                
                if line.isEmpty { continue }
                
                if let parsed = parseSSEEvent(line) {
                    switch parsed.type {
                    case "transcript.text.delta":
                        if let delta = parsed.delta, !delta.isEmpty {
                            fullText += delta
                            DispatchQueue.main.async {
                                onDelta?(delta)
                            }
                        }
                        
                    case "transcript.text.done":
                        // Final full text (optional fallback)
                        if let text = parsed.text, !text.isEmpty {
                            fullText = text
                        }
                        // We can break early if we have fullText already
                        
                    case "done":
                        break  // End of stream
                        
                    default:
                        print("Unknown event type: \(parsed.type)")
                    }
                }
            } else {
                lineBuffer += char
            }
        }
        
        if fullText.isEmpty {
            throw TranscriptionError.noTranscriptionInResponse
        }
        
        return fullText
    }
    
    private func parseSSEEvent(_ event: String) -> (type: String, delta: String?, text: String?)? {
        guard event.hasPrefix("data: ") else { return nil }
        let jsonStr = String(event.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if jsonStr == "[DONE]" {
            return ("done", nil, nil)
        }
        
        guard let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("Failed to parse JSON: \(jsonStr)")
            return nil
        }
        
        let type = json["type"] as? String ?? "unknown"
        let delta = json["delta"] as? String
        let text = json["text"] as? String
        
        return (type, delta, text)
    }
    
    // MARK: - Private Helpers
    
    private func loadApiKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            return envKey
        }
        
        let envPath = ".env"
        guard let envContent = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            return nil
        }
        
        for line in envContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("OPENAI_API_KEY=") {
                let key = String(trimmed.dropFirst("OPENAI_API_KEY=".count))
                return key.isEmpty ? nil : key
            }
        }
        
        return nil
    }
    
    private func convertToWAV(audioBuffer: [Float], sampleRate: Int) -> Data? {
        let int16Samples: [Int16] = audioBuffer.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }
        
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = UInt32(int16Samples.count * 2)
        let chunkSize = 36 + dataSize
        
        var wavData = Data()
        
        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(UInt32(chunkSize).littleEndianData)
        wavData.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(UInt32(16).littleEndianData)
        wavData.append(UInt16(1).littleEndianData)  // PCM
        wavData.append(numChannels.littleEndianData)
        wavData.append(UInt32(sampleRate).littleEndianData)
        wavData.append(byteRate.littleEndianData)
        wavData.append(blockAlign.littleEndianData)
        wavData.append(bitsPerSample.littleEndianData)
        
        // data chunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(dataSize.littleEndianData)
        
        for sample in int16Samples {
            wavData.append(sample.littleEndianData)
        }
        
        return wavData
    }
}