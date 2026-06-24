import AppKit
import SwiftUI
import Speech
import SharedModels
import ApplicationServices

// MARK: - Manager

/// Coordinates Apple native speech recognition with a floating NSPanel textarea UI.
/// Use AppleSpeechManager.shared as the app-wide singleton.
final class AppleSpeechManager: NSObject, ObservableObject, NSWindowDelegate {

    static let shared = AppleSpeechManager()

    @Published var transcriptionText = ""
    @Published var isListening = false
    @Published var statusMessage = "Press \u{2303}Space or tap Start to begin speaking"
    @Published var statusIsError = false

    private var transcriber: AppleSpeechTranscriber?
    private var panel: NSPanel?

    private override init() {
        super.init()
        transcriber = AppleSpeechTranscriber()
        transcriber?.delegate = self
    }

    // MARK: - Panel

    func showPanel() {
        if panel == nil { panel = buildPanel() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildPanel() -> NSPanel {
        let host = NSHostingController(rootView: AppleSpeechView(manager: self))
        host.view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "Apple Speech \u{2014} Voice to CLI"
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentViewController = host
        p.center()
        return p
    }

    /// Stop the mic when the panel is closed so recognition never keeps running unseen.
    func windowWillClose(_ notification: Notification) {
        if isListening { stopListening() }
    }

    // MARK: - Speech Control

    /// Records the frontmost app (e.g. Terminal) as the paste target — but never
    /// ourselves. Because the panel is a non-activating floating panel, clicking it
    /// does not steal focus from the CLI, so the CLI is still frontmost here.
    private func captureTargetApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        (NSApp.delegate as? AppDelegate)?.targetAppBeforeRecording = front
    }

    /// Ctrl+Space behaviour: stop if already listening, otherwise open + start.
    func toggle() {
        if isListening {
            stopListening()
        } else {
            showPanel()
            startListening()
        }
    }

    /// Opens System Settings → Privacy & Security → Speech Recognition.
    func openSpeechSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    func startListening() {
        guard !isListening else { return }
        captureTargetApp()
        transcriber?.requestPermission { [weak self] authorized in
            guard let self else { return }
            if authorized {
                do {
                    self.transcriptionText = ""
                    try self.transcriber?.startListening()
                } catch {
                    self.setStatus("⚠️ \(error.localizedDescription)", isError: true)
                }
            } else {
                self.setStatus("⚠️ Permission denied — enable Speech Recognition in System Settings → Privacy & Security.", isError: true)
            }
        }
    }

    func stopListening() {
        transcriber?.stopListening()
    }

    /// Pastes the transcript at the active cursor. The panel stays open for repeated
    /// use — pasteTextAtCursor() activates the previously focused app (captured when the
    /// panel opened), so the text lands in the CLI without dismissing the panel.
    func commitText() {
        let text = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Re-capture the target now (the CLI is still frontmost behind our
        // non-activating panel) in case focus changed since listening started.
        captureTargetApp()
        if isListening { stopListening() }
        // Brief delay so the target app is frontmost before the paste fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            (NSApp.delegate as? AppDelegate)?.pasteTextAtCursor(text)
        }
        transcriptionText = ""
        // Auto-paste needs Accessibility; without it pasteTextAtCursor falls back to
        // leaving the text on the clipboard, so tell the user how to finish the paste.
        if AXIsProcessTrusted() {
            setStatus("Sent ✓ — speak or press \u{2318}M to dictate again", isError: false)
        } else {
            setStatus("📋 Copied — press \u{2318}V to paste (grant Accessibility for auto-paste)", isError: true)
        }
    }

    func clearText() {
        transcriptionText = ""
        if !isListening {
            setStatus("Press \u{2303}Space or tap Start to begin speaking", isError: false)
        }
    }

    /// Copies the transcript to the clipboard without closing the panel — a manual
    /// fallback for when auto-paste can't reach the target app (press ⌘V yourself).
    func copyText() {
        let text = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Copied ✓ — press \u{2318}V to paste anywhere", isError: false)
    }

    // MARK: - Private

    private func setStatus(_ msg: String, isError: Bool) {
        statusMessage = msg
        statusIsError = isError
    }
}

// MARK: - AppleSpeechTranscriberDelegate
// The transcriber dispatches all callbacks to the main thread.

extension AppleSpeechManager: AppleSpeechTranscriberDelegate {

    func speechTranscriber(_ t: AppleSpeechTranscriber, didUpdateTranscription text: String, isFinal: Bool) {
        transcriptionText = text
        statusMessage = isFinal ? "Done — edit or press ⌘↵ to send" : "\u{0001F534} Listening…"
        statusIsError = false
    }

    func speechTranscriberDidStartListening(_ t: AppleSpeechTranscriber) {
        isListening = true
        setStatus("\u{0001F534} Listening — speak now…", isError: false)
    }

    func speechTranscriberDidStopListening(_ t: AppleSpeechTranscriber) {
        isListening = false
        statusMessage = transcriptionText.isEmpty
            ? "Press \u{2303}Space or tap Start to begin speaking"
            : "Done — edit or press ⌘↵ to send"
    }

    func speechTranscriber(_ t: AppleSpeechTranscriber, didFailWithError error: Error) {
        isListening = false
        setStatus("⚠️ \(error.localizedDescription)", isError: true)
    }
}

// MARK: - SwiftUI View

struct AppleSpeechView: View {
    @ObservedObject var manager: AppleSpeechManager
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {

            // Status bar
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.isListening ? Color.red : Color.clear)
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                               value: manager.isListening)
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundColor(manager.statusIsError ? .orange : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if manager.statusIsError {
                    Button("Settings") { manager.openSpeechSettings() }
                        .font(.caption)
                        .help("Open System Settings → Privacy & Security")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Live transcript textarea with placeholder
            ZStack(alignment: .topLeading) {
                TextEditor(text: $manager.transcriptionText)
                    .font(.system(size: 15))
                    .focused($editorFocused)
                    .padding(4)
                if manager.transcriptionText.isEmpty {
                    Text("Your spoken words will appear here in real time…")
                        .foregroundColor(.secondary)
                        .font(.system(size: 15))
                        .padding(.top, 9)
                        .padding(.leading, 9)
                        .allowsHitTesting(false)
                }
            }

            Divider()

            // Button bar
            HStack(spacing: 8) {
                Button {
                    manager.isListening ? manager.stopListening() : manager.startListening()
                } label: {
                    Label(
                        manager.isListening ? "Stop" : "Start",
                        systemImage: manager.isListening ? "stop.circle.fill" : "mic.circle"
                    )
                }
                .help(manager.isListening ? "Stop listening (⌘M)" : "Start listening (⌘M)")
                .keyboardShortcut("m", modifiers: .command)

                Button("Copy") { manager.copyText() }
                    .disabled(manager.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Copy transcript to clipboard — paste manually with ⌘V")

                Button("Clear") { manager.clearText() }
                    .disabled(manager.transcriptionText.isEmpty)
                    .help("Clear the transcript")

                Spacer()

                Button {
                    manager.commitText()
                } label: {
                    Label("Send to CLI", systemImage: "arrow.up.doc.on.clipboard")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(manager.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Paste transcript at cursor (⌘↵)")
            }
            .padding(10)
        }
        .frame(minWidth: 400, minHeight: 280)
        .onAppear { editorFocused = true }
    }
}
