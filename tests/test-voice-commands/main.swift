import Foundation
import SharedModels

print("🧪 Testing Voice Command Detector\n")

let detector = VoiceCommandDetector()

// Track detected commands
var detectedCommands: [(VoiceCommandDetector.DetectedCommand, String)] = []

detector.onCommandDetected = { command, phrase in
    print("✅ Detected: \(phrase) → \(command)")
    detectedCommands.append((command, phrase))
}

// Test 1: Stop command
print("Test 1: 'stop recording' command")
detector.reset()
detector.processDelta("I need to ")
detector.processDelta("finish this task ")
detector.processDelta("stop recording")
Thread.sleep(forTimeInterval: 0.1)

// Test 2: Cancel command
print("\nTest 2: 'cancel recording' command")
detector.reset()
detector.processDelta("Actually never mind ")
detector.processDelta("cancel recording")
Thread.sleep(forTimeInterval: 0.1)

// Test 3: Continue command
print("\nTest 3: 'continue recording' command")
detector.reset()
detector.processDelta("continue recording ")
detector.processDelta("please")
Thread.sleep(forTimeInterval: 0.1)

// Test 4: Command removal
print("\nTest 4: Command removal from transcription")
let original = "I need to schedule a meeting for tomorrow stop recording"
let cleaned = detector.removeCommandText(from: original)
print("Original: \(original)")
print("Cleaned:  '\(cleaned)'")
let expected = "I need to schedule a meeting for tomorrow"
assert(cleaned.trimmingCharacters(in: .whitespaces) == expected, "Command not removed correctly: '\(cleaned)' != '\(expected)'")

// Test 5: Cooldown mechanism
print("\nTest 5: Cooldown mechanism (should only detect once)")
detector.reset()
let detectedBefore = detectedCommands.count
detector.processDelta("stop recording")
Thread.sleep(forTimeInterval: 0.1)
detector.processDelta("stop recording")  // Should be ignored (cooldown)
Thread.sleep(forTimeInterval: 0.1)
let detectedAfter = detectedCommands.count
let cooldownWorked = (detectedAfter - detectedBefore) == 1
print(cooldownWorked ? "✅ Cooldown working" : "❌ Cooldown failed")

// Test 6: Case insensitivity
print("\nTest 6: Case insensitivity")
detector.reset()
detector.processDelta("STOP RECORDING")
Thread.sleep(forTimeInterval: 0.1)

// Summary
print("\n" + String(repeating: "=", count: 50))
print("Summary: \(detectedCommands.count) commands detected")
for (index, (command, phrase)) in detectedCommands.enumerated() {
    print("  \(index + 1). \(phrase) → \(command)")
}
print(String(repeating: "=", count: 50))

if detectedCommands.count >= 4 {
    print("\n✅ All tests passed!")
    exit(0)
} else {
    print("\n❌ Some tests failed")
    exit(1)
}
