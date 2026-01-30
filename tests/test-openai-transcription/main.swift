import Foundation

/// Test OpenAI audio transcription API with gpt-4o-transcribe model (true streaming)

func loadApiKey() -> String? {
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

func parseSSEEvent(_ event: String) -> (type: String, delta: String?, text: String?)? {
    // Extract JSON from "data: {...}" line
    guard event.hasPrefix("data: ") else { return nil }
    let jsonStr = String(event.dropFirst(6))

    if jsonStr == "[DONE]" { return ("done", nil, nil) }

    guard let jsonData = jsonStr.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return nil
    }

    let eventType = json["type"] as? String ?? "unknown"
    let delta = json["delta"] as? String
    let text = json["text"] as? String

    return (eventType, delta, text)
}

func transcribeAudioStreaming(fileURL: URL) async throws {
    guard let apiKey = loadApiKey() else {
        throw NSError(domain: "OpenAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "OPENAI_API_KEY not found"])
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw NSError(domain: "OpenAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio file not found"])
    }

    let audioData = try Data(contentsOf: fileURL)
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

    // File
    let filename = fileURL.lastPathComponent
    let mimeType: String
    switch fileURL.pathExtension.lowercased() {
    case "mp3": mimeType = "audio/mpeg"
    case "wav": mimeType = "audio/wav"
    case "m4a": mimeType = "audio/mp4"
    case "webm": mimeType = "audio/webm"
    default: mimeType = "audio/mpeg"
    }

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    print("📤 Sending \(filename) (\(audioData.count / 1024) KB) to OpenAI...")
    print("────────────────────────────────")

    let (bytes, response) = try await URLSession.shared.bytes(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(domain: "OpenAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
    }

    if httpResponse.statusCode != 200 {
        var errorData = Data()
        for try await byte in bytes {
            errorData.append(byte)
        }
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        throw NSError(domain: "OpenAI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "API error (\(httpResponse.statusCode)): \(errorMessage)"])
    }

    // Use AsyncLineSequence for simpler SSE parsing
    var fullText = ""
    var lineBuffer = ""

    for try await byte in bytes {
        guard let char = String(data: Data([byte]), encoding: .utf8) else { continue }

        if char == "\n" {
            // Process complete line
            let line = lineBuffer.trimmingCharacters(in: .whitespaces)
            lineBuffer = ""

            if line.isEmpty { continue }

            if let parsed = parseSSEEvent(line) {
                if parsed.type == "done" {
                    break
                }
                if let delta = parsed.delta {
                    print(delta, terminator: "")
                    fflush(stdout)
                    fullText += delta
                } else if let text = parsed.text, !text.isEmpty {
                    fullText = text
                }
            }
        } else {
            lineBuffer += char
        }
    }

    print("\n────────────────────────────────")
    print("✅ Transcription: \(fullText.count) characters")
    if !fullText.isEmpty {
        print("📜 Full text: \(fullText)")
    }
}

// Main
let args = CommandLine.arguments
if args.count < 2 {
    print("Usage: TestOpenAITranscription <audio-file>")
    print("Example: TestOpenAITranscription recording.wav")
    print("\nMake sure OPENAI_API_KEY is set in environment or .env file")
    exit(1)
}

let audioURL = URL(fileURLWithPath: args[1])

print("🎙️ OpenAI gpt-4o-transcribe (Streaming)")
print("========================================")

Task {
    do {
        try await transcribeAudioStreaming(fileURL: audioURL)
    } catch {
        print("\n❌ Error: \(error.localizedDescription)")
    }
    exit(0)
}

RunLoop.main.run()
