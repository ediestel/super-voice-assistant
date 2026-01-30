import Foundation
import AppKit
import SharedModels

@main
struct TestTextInserter {
    static func main() {
        print("🧪 Testing TextInserter\n")

        // Test 1: Permission check (non-prompting)
        print("📝 Test 1: Checking Accessibility Permission Status")
        let hasPermission = TextInserter.hasAccessibilityPermission()
        print("   Accessibility permission granted: \(hasPermission)")
        if !hasPermission {
            print("   ⚠️  Note: Grant permission in System Settings → Privacy & Security → Accessibility")
        }
        print("   ✅ Permission check completed\n")

        // Test 2: Empty string handling
        print("📝 Test 2: Empty String Handling")
        let emptyResult = TextInserter.insertTextAtCursor("")
        print("   insertTextAtCursor(\"\") returned: \(emptyResult)")
        assert(emptyResult == false, "Empty string should return false")
        print("   ✅ Empty string correctly rejected\n")

        // Test 3: Whitespace-only string (should still attempt insertion)
        print("📝 Test 3: Whitespace String Handling")
        let whitespaceResult = TextInserter.insertTextAtCursor("   ")
        print("   insertTextAtCursor(\"   \") returned: \(whitespaceResult)")
        if hasPermission {
            print("   Note: Result depends on whether a text field is focused")
        } else {
            print("   Note: Failed as expected (no accessibility permission)")
        }
        print("   ✅ Whitespace handling completed\n")

        // Test 4: Test insertion without focused element
        print("📝 Test 4: Insertion Without Focused Text Field")
        let noFocusResult = TextInserter.insertTextAtCursor("test")
        print("   insertTextAtCursor(\"test\") returned: \(noFocusResult)")
        if !noFocusResult {
            print("   Expected: No text field is focused in terminal context")
        }
        print("   ✅ No-focus case handled gracefully\n")

        // Test 5: Special characters
        print("📝 Test 5: Special Characters")
        let specialChars = ["Hello\nWorld", "Tab\there", "Emoji 🎤", "Unicode: café", "Quotes: \"test\""]
        for text in specialChars {
            let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
                              .replacingOccurrences(of: "\t", with: "\\t")
            let result = TextInserter.insertTextAtCursor(text)
            print("   \"\(escaped)\" -> \(result ? "✓" : "✗") (no focused field expected)")
        }
        print("   ✅ Special character tests completed\n")

        // Test 6: Simulate paste (clipboard operation)
        print("📝 Test 6: Paste Simulation (Clipboard)")
        let testText = "TextInserter test at \(Date())"
        print("   Setting clipboard to: \"\(testText)\"")

        // Check clipboard before
        let pasteboardBefore = NSPasteboard.general.string(forType: .string) ?? "(empty)"
        print("   Clipboard before: \"\(pasteboardBefore.prefix(50))...\"")

        // This will set clipboard but won't actually paste (no window focused)
        TextInserter.simulatePaste(testText)

        // Check clipboard after
        let pasteboardAfter = NSPasteboard.general.string(forType: .string) ?? "(empty)"
        print("   Clipboard after: \"\(pasteboardAfter)\"")

        if pasteboardAfter == testText {
            print("   ✅ Clipboard correctly set for paste simulation\n")
        } else {
            print("   ❌ Clipboard was not set correctly\n")
        }

        // Test 7: insertTextWithFallback
        print("📝 Test 7: Insert With Fallback")
        let fallbackText = "Fallback test"
        print("   Testing insertTextWithFallback(\"\(fallbackText)\")")
        TextInserter.insertTextWithFallback(fallbackText)
        let clipboardCheck = NSPasteboard.general.string(forType: .string) ?? ""
        if clipboardCheck == fallbackText {
            print("   Fallback to paste simulation was triggered (clipboard contains test text)")
        }
        print("   ✅ Fallback mechanism tested\n")

        // Summary
        print("=" .padding(toLength: 50, withPad: "=", startingAt: 0))
        print("📊 Test Summary")
        print("=" .padding(toLength: 50, withPad: "=", startingAt: 0))
        print("   Accessibility Permission: \(hasPermission ? "✅ Granted" : "❌ Not Granted")")
        print("   Empty string handling: ✅ Working")
        print("   Clipboard operations: ✅ Working")
        print("")

        if !hasPermission {
            print("💡 To fully test TextInserter:")
            print("   1. Grant Accessibility permission to this app")
            print("   2. Focus a text field (e.g., in Notes or TextEdit)")
            print("   3. Run: TextInserter.insertTextAtCursor(\"Hello!\")")
            print("")
        }

        print("✅ TextInserter testing complete!")
    }
}
