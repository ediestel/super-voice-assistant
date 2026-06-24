import Foundation
import SharedModels

// Smoke test for AppleSpeechTranscriber's public surface.
// It does NOT start the microphone (that needs runtime permission); it exercises
// the non-audio API so regressions in the public interface are caught at build/run time.

var failures = 0

func check(_ cond: Bool, _ label: String) {
    if cond {
        print("✅ \(label)")
    } else {
        print("❌ \(label)")
        failures += 1
    }
}

// 1. Transcriber initializes and starts idle.
let transcriber = AppleSpeechTranscriber()
check(!transcriber.isListening, "transcriber starts not listening")

// 2. Authorization status is queryable without crashing.
let status = AppleSpeechTranscriber.authorizationStatus
print("ℹ️ authorization status raw value: \(status.rawValue)")
check(true, "authorizationStatus is queryable")

// 3. Error provides a user-facing description.
let err = AppleSpeechError.recognizerUnavailable
check(!(err.errorDescription ?? "").isEmpty, "AppleSpeechError has a description")

// 4. Delegate protocol can be satisfied and assigned.
final class MockDelegate: AppleSpeechTranscriberDelegate {
    func speechTranscriber(_ t: AppleSpeechTranscriber, didUpdateTranscription text: String, isFinal: Bool) {}
    func speechTranscriberDidStartListening(_ t: AppleSpeechTranscriber) {}
    func speechTranscriberDidStopListening(_ t: AppleSpeechTranscriber) {}
    func speechTranscriber(_ t: AppleSpeechTranscriber, didFailWithError error: Error) {}
}
let mock = MockDelegate()
transcriber.delegate = mock
check(transcriber.delegate === mock, "delegate can be assigned")

// 5. stopListening is safe to call when never started (idempotent teardown).
transcriber.stopListening()
check(!transcriber.isListening, "stopListening is safe when idle")

if failures == 0 {
    print("\n🎉 All Apple Speech smoke tests passed")
    exit(0)
} else {
    print("\n💥 \(failures) Apple Speech smoke test(s) failed")
    exit(1)
}
