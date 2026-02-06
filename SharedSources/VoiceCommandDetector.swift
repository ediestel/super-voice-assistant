import Foundation

/// Detects voice commands in real-time transcription stream
/// Commands: "stop recording", "cancel recording", "continue", "pause"
public class VoiceCommandDetector {

    // Command patterns (case-insensitive)
    private enum Command: String, CaseIterable {
        case stop = "stop recording"
        case cancel = "cancel recording"
        case pause = "pause recording"
        case resume = "continue recording"
        case done = "done recording"

        var aliases: [String] {
            switch self {
            case .stop:
                return ["stop", "stop recording", "halt recording", "finish recording"]
            case .cancel:
                return ["cancel", "cancel recording", "discard", "discard recording"]
            case .pause:
                return ["pause", "pause recording", "hold on"]
            case .resume:
                return ["continue", "continue recording", "resume", "resume recording", "keep going"]
            case .done:
                return ["done", "done recording", "that's all", "end recording"]
            }
        }
    }

    public enum DetectedCommand {
        case stop
        case cancel
        case pause
        case resume
        case done
    }

    // Callbacks
    public var onCommandDetected: ((DetectedCommand, String) -> Void)?

    // Configuration
    public var isEnabled: Bool = true
    public var minimumConfidence: Double = 0.7
    public var commandWindowSeconds: Double = 3.0 // Look at last N seconds of transcription

    // Internal state
    private var recentTranscription: String = ""
    private var lastCommandTime: Date?
    private let commandCooldown: TimeInterval = 2.0 // Prevent duplicate detections
    private let lock = NSLock()

    public init() {}

    /// Process incoming transcription delta
    /// - Parameter delta: New transcription text from real-time API
    public func processDelta(_ delta: String) {
        guard isEnabled else { return }

        lock.lock()
        recentTranscription += delta

        // Keep only last N seconds worth of text (approximate by character count)
        let maxLength = Int(commandWindowSeconds * 50) // ~50 chars/second speaking rate
        if recentTranscription.count > maxLength {
            let startIndex = recentTranscription.index(recentTranscription.endIndex, offsetBy: -maxLength)
            recentTranscription = String(recentTranscription[startIndex...])
        }
        lock.unlock()

        detectCommands()
    }

    /// Reset the detector state (call when starting new recording)
    public func reset() {
        lock.lock()
        recentTranscription = ""
        lastCommandTime = nil
        lock.unlock()
    }

    /// Detect commands in recent transcription
    private func detectCommands() {
        lock.lock()
        let text = recentTranscription.lowercased()
        lock.unlock()

        // Check cooldown
        if let lastTime = lastCommandTime,
           Date().timeIntervalSince(lastTime) < commandCooldown {
            return
        }

        // Check each command type
        for command in Command.allCases {
            for alias in command.aliases {
                if text.contains(alias.lowercased()) {
                    // Command detected!
                    let detectedCommand = mapToDetectedCommand(command)
                    lock.lock()
                    lastCommandTime = Date()
                    lock.unlock()

                    print("🎤 Voice command detected: \(alias)")
                    onCommandDetected?(detectedCommand, alias)

                    // Clear recent transcription to prevent re-detection
                    lock.lock()
                    recentTranscription = ""
                    lock.unlock()
                    return
                }
            }
        }
    }

    private func mapToDetectedCommand(_ command: Command) -> DetectedCommand {
        switch command {
        case .stop: return .stop
        case .cancel: return .cancel
        case .pause: return .pause
        case .resume: return .resume
        case .done: return .done
        }
    }

    /// Extract command text from transcription for removal
    /// - Parameter transcription: Full transcription text
    /// - Returns: Cleaned transcription with command removed
    public func removeCommandText(from transcription: String) -> String {
        var cleaned = transcription

        // Sort aliases by length (longest first) to match multi-word commands first
        var allAliases: [String] = []
        for command in Command.allCases {
            allAliases.append(contentsOf: command.aliases)
        }
        allAliases.sort { $0.count > $1.count }

        for alias in allAliases {
            // Escape special regex characters in the alias
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            // Match word boundaries for cleaner removal
            let pattern = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive)
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            if let pattern = pattern {
                cleaned = pattern.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }

        // Clean up extra whitespace (multiple spaces become single space)
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }
}
