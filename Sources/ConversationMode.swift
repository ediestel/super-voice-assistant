import AppKit
import Carbon.HIToolbox
import SharedModels

// MARK: - Conversation Mode

/// Hands-free turn-by-turn dictation into whatever text field has the cursor
/// (e.g. a chat with an LLM). Words are typed live as they are recognized; the turn
/// is sent with Return after `silenceBeforeSend` seconds without new words. Listening
/// then continues for the next turn.
///
/// Fn+⌃⌥: off → on; on → off. Turning off never presses Return; unsent text stays in the field.
final class ConversationMode {

    static let shared = ConversationMode()

    private let silenceBeforeSend: TimeInterval = 7

    private(set) var isActive = false
    /// Called on the main thread when the mode turns on or off.
    var onActiveChange: ((Bool) -> Void)?

    private let transcriber = AppleSpeechTranscriber()
    private let delegateProxy = TranscriberProxy()
    /// What has been typed for the current recognition session (diffed against new results).
    private var typed = ""
    /// True once the current turn has any text in the target field.
    private var turnHasText = false
    /// The recognizer ended on its own mid-turn: separate the next session's words with a space.
    private var needsSpace = false
    private var silenceTimer: Timer?

    private init() {
        delegateProxy.owner = self
        transcriber.delegate = delegateProxy
    }

    // MARK: Hotkey

    func handleHotkey() {
        print("🗣 Conversation hotkey (active=\(isActive), turnHasText=\(turnHasText))")
        if isActive {
            stop()
        } else {
            start()
        }
    }

    // MARK: Control

    func start() {
        guard !isActive else { return }
        // The floating panel uses its own recognizer on the same microphone.
        if AppleSpeechManager.shared.isListening { AppleSpeechManager.shared.stopListening() }
        transcriber.requestPermission { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                self.notify("Speech Recognition permission denied — enable it in System Settings → Privacy & Security.")
                return
            }
            self.isActive = true
            self.resetTurn()
            self.onActiveChange?(true)
            NSSound(named: "Tink")?.play()
            self.listen()
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        transcriber.stopListening()
        resetTurn()
        onActiveChange?(false)
        NSSound(named: "Pop")?.play()
    }

    private func listen() {
        print("🗣 Conversation: start session")
        typed = ""
        do {
            try transcriber.startListening()
        } catch {
            stop()
            notify(error.localizedDescription)
        }
    }

    /// Presses Return in the target field and starts a fresh recognition session,
    /// so the next turn's text does not contain this one's.
    private func sendTurn() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard turnHasText else { return }
        print("🗣 Conversation: send turn")
        Keyboard.press(CGKeyCode(kVK_Return))
        resetTurn()
        // Stopping ends the session; the stop callback starts the next one.
        transcriber.stopListening()
    }

    private func resetTurn() {
        typed = ""
        turnHasText = false
        needsSpace = false
    }

    // MARK: Transcriber events (main thread)

    fileprivate func didUpdate(_ text: String) {
        // Results queued before a stop (sent turn) must not be typed into the next turn.
        guard isActive, transcriber.isListening else { return }
        // After a short pause the recognizer starts a new segment and reports only the words
        // since then. Text with nothing in common with what is typed is such a segment: keep
        // what is typed and continue after it, instead of deleting it.
        let previous = needsSpace ? String(typed.dropFirst()) : typed
        if previous.contains(" "), !text.isEmpty, previous.first != text.first {
            typed = ""
            needsSpace = true
        }
        var target = text
        if needsSpace && !target.isEmpty { target = " " + target }
        guard target != typed else { return }

        // Retype only what changed: the recognizer revises recent words as it goes.
        let common = zip(typed, target).prefix { $0 == $1 }.count
        print("🗣 Conversation: update \"\(target)\" (delete \(typed.count - common), type \(target.count - common))")
        Keyboard.backspace(typed.count - common)
        Keyboard.type(String(target.dropFirst(common)))
        typed = target
        if !target.isEmpty { turnHasText = true }

        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceBeforeSend, repeats: false) { [weak self] _ in
            self?.sendTurn()
        }
    }

    fileprivate func didStop() {
        print("🗣 Conversation: session ended (active=\(isActive))")
        guard isActive else { return }
        // The recognizer also ends on its own (long silence, "no speech" error). Keep the
        // turn's text and continue listening; the next session's words get a leading space.
        if turnHasText { needsSpace = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isActive, !self.transcriber.isListening else { return }
            self.listen()
        }
    }

    private func notify(_ message: String) {
        let notification = NSUserNotification()
        notification.title = "Conversation Mode"
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
        print("⚠️ Conversation mode: \(message)")
    }
}

/// Forwards transcriber callbacks; errors end the session, which `didStop` handles.
private final class TranscriberProxy: AppleSpeechTranscriberDelegate {
    weak var owner: ConversationMode?

    func speechTranscriber(_ t: AppleSpeechTranscriber, didUpdateTranscription text: String, isFinal: Bool) {
        owner?.didUpdate(text)
    }
    func speechTranscriberDidStartListening(_ t: AppleSpeechTranscriber) {}
    func speechTranscriberDidStopListening(_ t: AppleSpeechTranscriber) {
        owner?.didStop()
    }
    func speechTranscriber(_ t: AppleSpeechTranscriber, didFailWithError error: Error) {
        print("Conversation mode recognizer: \(error.localizedDescription)")
    }
}

// MARK: - Synthetic keyboard

private enum Keyboard {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func press(_ key: CGKeyCode) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        // Explicitly no modifiers, so a held key can't turn Return into a shortcut.
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func backspace(_ count: Int) {
        for _ in 0..<max(count, 0) { press(CGKeyCode(kVK_Delete)) }
    }

    /// Types text as Unicode key events, in chunks of whole characters
    /// (events carry at most ~20 UTF-16 units reliably).
    static func type(_ text: String) {
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 20 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }
}

// MARK: - Fn+⌃⌥ hotkey

/// Detects a press of Fn+Control+Option with no other key: fires when the three are
/// released together. The shortcut library can't express modifier-only combos or Fn.
final class FnControlOptionHotkey {
    private let chord: NSEvent.ModifierFlags = [.function, .control, .option]
    private let watched: NSEvent.ModifierFlags = [.function, .control, .option, .command, .shift]
    private var armed = false
    private var spoiled = false
    private var monitors: [Any] = []
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        // Global monitors see other apps' events (needs Accessibility); local ones see ours.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] in self?.handle($0) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(m)
        }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            // Fn+⌃⌥+<key> is someone else's shortcut.
            if armed { spoiled = true }
            return
        }
        let flags = event.modifierFlags.intersection(watched)
        if flags == chord {
            if !armed { armed = true; spoiled = false }
        } else if flags.isEmpty {
            if armed && !spoiled { action() }
            armed = false
        } else if armed && !flags.isSubset(of: chord) {
            spoiled = true
        }
    }
}
