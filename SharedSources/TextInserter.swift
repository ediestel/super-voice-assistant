import ApplicationServices
import AppKit
import Carbon.HIToolbox

/// Helper for inserting text at the current system cursor using Accessibility API
/// Requires: App has Accessibility permissions enabled in System Settings
public struct TextInserter {

    /// Inserts text at the current system cursor using Accessibility API
    /// - Parameter text: The text to insert at the cursor position
    /// - Returns: true if insertion succeeded, false otherwise
    @discardableResult
    public static func insertTextAtCursor(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        // 1. Get system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()

        // 2. Get the currently focused UI element
        var focusedElement: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard error == .success, let focused = focusedElement else {
            print("⚠️ TextInserter: Could not get focused element (error: \(error.rawValue))")
            return false
        }

        // AXUIElement is a CFTypeRef, safe to cast after success check
        let axElement = focused as! AXUIElement

        // 3. Set the selected text attribute → this inserts at cursor / replaces selection
        let cfText = text as CFTypeRef
        let setError = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            cfText
        )

        if setError == .success {
            print("✅ TextInserter: Inserted \(text.count) characters")
            return true
        } else {
            print("❌ TextInserter: AXUIElementSetAttributeValue failed: \(setError.rawValue)")
            return false
        }
    }

    /// Inserts text with automatic fallback to paste simulation if Accessibility fails
    /// - Parameter text: The text to insert at the cursor position
    public static func insertTextWithFallback(_ text: String) {
        guard !text.isEmpty else { return }

        if !insertTextAtCursor(text) {
            print("⚠️ TextInserter: Falling back to paste simulation")
            simulatePaste(text)
        }
    }

    /// Fallback: Simulate Cmd+V paste by copying text to clipboard and triggering paste
    /// Less precise than Accessibility API but requires fewer permissions
    /// - Parameter text: The text to paste
    public static func simulatePaste(_ text: String) {
        // Save current clipboard contents
        let pasteboard = NSPasteboard.general

        // Set new text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Create event source
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("❌ TextInserter: Could not create event source")
            return
        }

        // Virtual key codes
        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)  // 0x09
        let cmdKeyCode: CGKeyCode = CGKeyCode(kVK_Command)  // 0x37

        // Create key events
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false) else {
            print("❌ TextInserter: Could not create key events")
            return
        }

        // Set command flag for V key events
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // Post events in sequence
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)

        print("✅ TextInserter: Simulated paste for \(text.count) characters")
    }

    /// Check if the app has Accessibility permissions
    /// - Returns: true if Accessibility access is granted
    public static func hasAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Request Accessibility permissions (shows system prompt if not granted)
    /// - Returns: true if already granted, false if prompt was shown
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
