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

    /// Modifiers we must not have held down when we synthesize ⌘V, or our
    /// command flag collides with the live keyboard state and the paste is dropped.
    private static let conflictingModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]

    /// Block (briefly) until the user has released the hotkey modifiers.
    /// Polls the real hardware modifier state so a still-held ⌘/⌥/⌃/⇧ from the
    /// activation chord can't corrupt the synthetic ⌘V. Bounded so we never hang.
    private static func waitForModifierRelease(timeout: TimeInterval = 0.5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let held = CGEventSource.flagsState(.combinedSessionState)
            if held.intersection(conflictingModifiers).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Snapshot the pasteboard as restorable items (deep copy of every type/payload).
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy.types.isEmpty ? nil : copy
        } ?? []
    }

    /// Fallback: Simulate Cmd+V paste by copying text to clipboard and triggering paste.
    /// Less precise than Accessibility API but requires fewer permissions.
    ///
    /// Polished behaviour: saves and restores the user's clipboard, waits for the
    /// activation modifiers to be released, and paces the key events so the target
    /// app reliably sees the ⌘ flag before V and the pasteboard write before paste.
    /// - Parameter text: The text to paste
    public static func simulatePaste(_ text: String) {
        let pasteboard = NSPasteboard.general

        // 1. Save the user's clipboard so we can put it back afterwards.
        let saved = snapshotPasteboard(pasteboard)
        let savedChangeCount = pasteboard.changeCount

        // 2. Stage our text.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Don't fight the user's still-held hotkey modifiers.
        waitForModifierRelease()

        // 4. Create event source.
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("❌ TextInserter: Could not create event source")
            return
        }

        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        let cmdKeyCode = CGKeyCode(kVK_Command)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false) else {
            print("❌ TextInserter: Could not create key events")
            return
        }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // 5. Let the pasteboard write settle so the target app reads our text, not stale data.
        Thread.sleep(forTimeInterval: 0.02)

        // 6. Post with small settle gaps so ⌘ registers before V.
        cmdDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.005)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.005)
        cmdUp.post(tap: .cghidEventTap)

        print("✅ TextInserter: Simulated paste for \(text.count) characters")

        // 7. Restore the user's clipboard once the target has consumed the paste.
        //    Guard on changeCount so we don't stomp anything the user copied meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pasteboard.changeCount == savedChangeCount + 1 else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
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
