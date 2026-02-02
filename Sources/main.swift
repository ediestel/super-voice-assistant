import Cocoa
import SwiftUI
import KeyboardShortcuts
import AVFoundation
import SharedModels
import Combine
import ApplicationServices
import Foundation
import CoreGraphics

// Environment variable loading - uses shared EnvironmentLoader
func loadEnvironmentVariables() {
    EnvironmentLoader.load()
}

extension KeyboardShortcuts.Name {
    static let showHistory = Self("showHistory")
    static let readSelectedText = Self("readSelectedText")
    static let toggleScreenRecording = Self("toggleScreenRecording")
    static let geminiAudioRecording = Self("geminiAudioRecording")
    static let openaiAudioRecording = Self("openaiAudioRecording")
}

class AppDelegate: NSObject, NSApplicationDelegate, GeminiAudioRecordingManagerDelegate, OpenAIAudioRecordingManagerDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: SettingsWindowController?
    private var unifiedWindow: UnifiedManagerWindow?

    private var geminiAudioManager: GeminiAudioRecordingManager!
    private var openaiAudioManager: OpenAIAudioRecordingManager!
    private var streamingPlayer: GeminiStreamingPlayer?
    private var audioCollector: GeminiAudioCollector?
    private var _isCurrentlyPlaying = false
    private let playingLock = NSLock()
    private var isCurrentlyPlaying: Bool {
        get {
            playingLock.lock()
            defer { playingLock.unlock() }
            return _isCurrentlyPlaying
        }
        set {
            playingLock.lock()
            _isCurrentlyPlaying = newValue
            playingLock.unlock()
        }
    }
    private var currentStreamingTask: Task<Void, Never>?
    private var screenRecorder = ScreenRecorder()
    private var currentVideoURL: URL?
    private var videoTranscriber = VideoTranscriber()
    private var targetAppBeforeRecording: NSRunningApplication?

    // State manager for centralized recording state
    private let stateManager = RecordingStateManager.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permissions
        let trusted = AXIsProcessTrusted()
        print(trusted ? "✅ Accessibility: GRANTED" : "❌ Accessibility: NOT GRANTED")

        if !trusted {
            // Show alert to user
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Auto-paste won't work without Accessibility access.\n\nGo to: System Settings > Privacy & Security > Accessibility\n\nAdd Terminal (if using swift run) or SuperVoiceAssistant app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Continue Anyway")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            // Also prompt via system
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        // Load environment variables
        loadEnvironmentVariables()
        
        // Initialize streaming TTS components if API key is available
        if let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty {
            if #available(macOS 14.0, *) {
                streamingPlayer = GeminiStreamingPlayer(playbackSpeed: 1.15)
                audioCollector = GeminiAudioCollector(apiKey: apiKey)
                print("✅ Streaming TTS components initialized")
            } else {
                print("⚠️ Streaming TTS requires macOS 14.0 or later")
            }
        } else {
            print("⚠️ GEMINI_API_KEY not found in environment variables")
        }
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Set the waveform icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
        }
        
        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "OpenAI Audio Recording: Press Command+Option+Z", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Gemini Audio Recording: Press Command+Option+X", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "History: Press Command+Option+A", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Read Selected Text: Press Command+Option+S", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Screen Recording: Press Command+Option+C", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Test Auto-Paste", action: #selector(testAutoPaste), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "View History...", action: #selector(showTranscriptionHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Statistics...", action: #selector(showStats), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Reset any cached shortcuts first
        KeyboardShortcuts.reset(.openaiAudioRecording)

        // Set keyboard shortcuts: Z=OpenAI
        KeyboardShortcuts.setShortcut(.init(.z, modifiers: [.command, .option]), for: .openaiAudioRecording)
        // Gemini disabled - uncomment to enable:
        // KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .option]), for: .geminiAudioRecording)
        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .option]), for: .showHistory)
        KeyboardShortcuts.setShortcut(.init(.s, modifiers: [.command, .option]), for: .readSelectedText)
        KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.command, .option]), for: .toggleScreenRecording)

        // Debug: Print registered shortcuts
        print("🔧 Shortcuts registered:")
        print("   Cmd+Opt+Z: OpenAI Realtime")
        print("   Cmd+Opt+A: History")
        print("   Cmd+Opt+S: TTS")
        print("   Cmd+Opt+C: Screen")
        
        // Set up keyboard shortcut handlers
        KeyboardShortcuts.onKeyUp(for: .showHistory) { [weak self] in
            self?.showTranscriptionHistory()
        }
        
        KeyboardShortcuts.onKeyUp(for: .readSelectedText) { [weak self] in
            self?.handleReadSelectedTextToggle()
        }

        KeyboardShortcuts.onKeyUp(for: .geminiAudioRecording) { [weak self] in
            guard let self = self else { return }

            // Prevent starting Gemini audio recording if screen recording is active
            if self.screenRecorder.recording {
                let notification = NSUserNotification()
                notification.title = "Cannot Start Gemini Audio Recording"
                notification.informativeText = "Screen recording is currently active. Stop it first with Cmd+Option+C"
                NSUserNotificationCenter.default.deliver(notification)
                print("⚠️ Blocked Gemini audio recording - screen recording is active")
                return
            }

            // Use state manager for mutual exclusion check
            if !self.stateManager.canStart(source: .gemini) && !self.geminiAudioManager.isRecording {
                let notification = NSUserNotification()
                notification.title = "Cannot Start Gemini Audio Recording"
                notification.informativeText = "Another recording is currently active"
                NSUserNotificationCenter.default.deliver(notification)
                print("Blocked Gemini audio recording - another recording is active")
                return
            }

            // If about to start a fresh recording, capture target app
            if !self.geminiAudioManager.isRecording {
                self.targetAppBeforeRecording = NSWorkspace.shared.frontmostApplication
            }
            self.geminiAudioManager.toggleRecording()
        }

        KeyboardShortcuts.onKeyUp(for: .openaiAudioRecording) { [weak self] in
            print("🟡 Cmd+Opt+Z pressed - OpenAI Realtime!")
            guard let self = self else { return }

            // Prevent starting OpenAI audio recording if screen recording is active
            if self.screenRecorder.recording {
                let notification = NSUserNotification()
                notification.title = "Cannot Start OpenAI Audio Recording"
                notification.informativeText = "Screen recording is currently active. Stop it first with Cmd+Option+C"
                NSUserNotificationCenter.default.deliver(notification)
                print("Blocked OpenAI audio recording - screen recording is active")
                return
            }

            // Use state manager for mutual exclusion check
            if !self.stateManager.canStart(source: .openai) && !self.openaiAudioManager.isRecording {
                let notification = NSUserNotification()
                notification.title = "Cannot Start OpenAI Audio Recording"
                notification.informativeText = "Another recording is currently active"
                NSUserNotificationCenter.default.deliver(notification)
                print("Blocked OpenAI audio recording - another recording is active")
                return
            }

            // If about to start a fresh recording, capture target app
            if !self.openaiAudioManager.isRecording {
                self.targetAppBeforeRecording = NSWorkspace.shared.frontmostApplication
            }
            self.openaiAudioManager.toggleRecording()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleScreenRecording) { [weak self] in
            self?.toggleScreenRecording()
        }

        // Set up Gemini audio manager
        geminiAudioManager = GeminiAudioRecordingManager()
        geminiAudioManager.delegate = self

        // Set up OpenAI audio manager
        openaiAudioManager = OpenAIAudioRecordingManager()
        openaiAudioManager.delegate = self

        // Register for state changes to update status bar
        stateManager.onStateChange { [weak self] state, source in
            DispatchQueue.main.async {
                self?.handleRecordingStateChange(state: state, source: source)
            }
        }
    }

    private func handleRecordingStateChange(state: RecordingState, source: RecordingSource?) {
        // Don't update status bar if screen recording is active
        if screenRecorder.recording { return }

        switch state {
        case .idle:
            // Reset to default icon
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
                button.title = ""
            }
        case .starting, .recording:
            // Green dot while recording
            if let button = statusItem.button {
                button.image = nil
                button.title = "🟢"
            }
        case .processing:
            // Blue dot for processing
            if let button = statusItem.button {
                button.image = nil
                button.title = "🔵"
            }
        case .continueMode:
            // Yellow dot in continue mode
            showContinueModeIndicator()
        }
    }
    

    
    @objc func openSettings() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .settings)
    }
    
    @objc func showTranscriptionHistory() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .history)
    }
    
    @objc func showStats() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .statistics)
    }

    @objc func testAutoPaste() {
        print("🧪 TEST: Starting auto-paste test...")
        print("🧪 TEST: AXIsProcessTrusted = \(AXIsProcessTrusted())")

        // Save current frontmost app before clicking menu
        let targetApp = NSWorkspace.shared.frontmostApplication
        print("🧪 TEST: Target app = \(targetApp?.localizedName ?? "none")")

        // Small delay to let user click into a text field
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            let testText = "[TEST PASTE SUCCESS]"
            print("🧪 TEST: Calling pasteTextAtCursor with: \(testText)")
            self?.pasteTextAtCursor(testText)
            print("🧪 TEST: pasteTextAtCursor completed")
        }
    }

    func handleReadSelectedTextToggle() {
        // If currently playing, stop the audio
        if isCurrentlyPlaying {
            stopCurrentPlayback()
            return
        }

        // Otherwise, start reading selected text
        readSelectedText()
    }

    func toggleScreenRecording() {
        // Prevent starting screen recording if Gemini audio recording is active
        if !screenRecorder.recording && geminiAudioManager.isRecording {
            let notification = NSUserNotification()
            notification.title = "Cannot Start Screen Recording"
            notification.informativeText = "Gemini audio recording is currently active. Stop it first with Cmd+Option+X"
            NSUserNotificationCenter.default.deliver(notification)
            print("Blocked screen recording - Gemini audio recording is active")
            return
        }

        // Prevent starting screen recording if OpenAI audio recording is active
        if !screenRecorder.recording && openaiAudioManager.isRecording {
            let notification = NSUserNotification()
            notification.title = "Cannot Start Screen Recording"
            notification.informativeText = "OpenAI audio recording is currently active. Stop it first with Cmd+Option+Z"
            NSUserNotificationCenter.default.deliver(notification)
            print("Blocked screen recording - OpenAI audio recording is active")
            return
        }

        if screenRecorder.recording {
            // Stop recording
            screenRecorder.stopRecording { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let videoURL):
                    self.currentVideoURL = videoURL

                    // Start video processing indicator
                    self.startVideoProcessingIndicator()

                    // Transcribe the video
                    print("🎬 Starting transcription for: \(videoURL.lastPathComponent)")
                    self.videoTranscriber.transcribe(videoURL: videoURL) { result in
                        DispatchQueue.main.async {
                            self.stopVideoProcessingIndicator()

                            switch result {
                            case .success(var transcription):
                                // Apply text replacements from config
                                transcription = TextReplacements.shared.processText(transcription)

                                // Save to history
                                TranscriptionHistory.shared.addEntry(transcription)

                                // Paste transcription at cursor
                                self.pasteTextAtCursor(transcription)

                                // Delete the video file after successful transcription
                                if let videoURL = self.currentVideoURL {
                                    do {
                                        try FileManager.default.removeItem(at: videoURL)
                                        print("🗑️ Deleted video file: \(videoURL.lastPathComponent)")
                                    } catch {
                                        print("⚠️ Failed to delete video file: \(error.localizedDescription)")
                                    }
                                }

                                // Show completion notification with transcription
                                let completionNotification = NSUserNotification()
                                completionNotification.title = "Video Transcribed"
                                completionNotification.informativeText = transcription.prefix(100) + (transcription.count > 100 ? "..." : "")
                                completionNotification.subtitle = "Pasted at cursor"
                                NSUserNotificationCenter.default.deliver(completionNotification)

                                print("✅ Transcription complete:")
                                print("─────────────────")
                                print(transcription)
                                print("─────────────────")

                            case .failure(let error):
                                // Show error notification
                                let errorNotification = NSUserNotification()
                                errorNotification.title = "Transcription Failed"
                                errorNotification.informativeText = error.localizedDescription
                                NSUserNotificationCenter.default.deliver(errorNotification)

                                print("❌ Transcription failed: \(error.localizedDescription)")
                            }
                        }
                    }

                case .failure(let error):
                    print("❌ Screen recording failed: \(error.localizedDescription)")

                    let errorNotification = NSUserNotification()
                    errorNotification.title = "Recording Failed"
                    errorNotification.informativeText = error.localizedDescription
                    NSUserNotificationCenter.default.deliver(errorNotification)

                    // Reset status bar
                    if let button = self.statusItem.button {
                        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
                        button.title = ""
                    }
                }
            }

            // Show stopping notification
            let notification = NSUserNotification()
            notification.title = "Screen Recording Stopped"
            notification.informativeText = "Saving video..."
            NSUserNotificationCenter.default.deliver(notification)
            print("⏹️ Screen recording STOPPED")

        } else {
            // Start recording
            screenRecorder.startRecording { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let videoURL):
                    self.currentVideoURL = videoURL

                    // Update status bar to show recording indicator
                    if let button = self.statusItem.button {
                        button.image = nil
                        button.title = "🔴"
                    }

                    // Show success notification
                    let notification = NSUserNotification()
                    notification.title = "Screen Recording Started"
                    notification.informativeText = "Press Cmd+Option+C again to stop"
                    NSUserNotificationCenter.default.deliver(notification)
                    print("🎥 Screen recording STARTED")

                case .failure(let error):
                    print("❌ Failed to start recording: \(error.localizedDescription)")

                    let errorNotification = NSUserNotification()
                    errorNotification.title = "Recording Failed"
                    errorNotification.informativeText = error.localizedDescription
                    NSUserNotificationCenter.default.deliver(errorNotification)
                }
            }
        }
    }

    func stopCurrentPlayback() {
        print("🛑 Stopping audio playback")
        
        // Cancel the current streaming task
        currentStreamingTask?.cancel()
        currentStreamingTask = nil
        
        // Stop the audio player
        streamingPlayer?.stopAudioEngine()
        
        // Reset playing state
        isCurrentlyPlaying = false
        
        let notification = NSUserNotification()
        notification.title = "Audio Stopped"
        notification.informativeText = "Text-to-speech playback stopped"
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func readSelectedText() {
        // Save current clipboard contents first
        let pasteboard = NSPasteboard.general
        let savedTypes = pasteboard.types ?? []
        var savedItems: [NSPasteboard.PasteboardType: Data] = [:]
        
        for type in savedTypes {
            if let data = pasteboard.data(forType: type) {
                savedItems[type] = data
            }
        }
        
        print("📋 Saved \(savedItems.count) clipboard types before reading selection")
        
        // Simulate Cmd+C to copy selected text
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDownC = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let keyUpC = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            print("❌ Failed to create CGEvent for Cmd+C - Accessibility permission required")
            return
        }

        // Set Cmd modifier and post
        keyDownC.flags = .maskCommand
        keyUpC.flags = .maskCommand
        keyDownC.post(tap: .cghidEventTap)
        keyUpC.post(tap: .cghidEventTap)
        
        // Give system a moment to process the copy command
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // Read from clipboard
            let copiedText = pasteboard.string(forType: .string) ?? ""
            
            if !copiedText.isEmpty {
                print("📖 Selected text for streaming TTS: \(copiedText)")
                
                // Try to stream speech with our streaming components
                if let audioCollector = self?.audioCollector, let streamingPlayer = self?.streamingPlayer {
                    self?.isCurrentlyPlaying = true
                    
                    self?.currentStreamingTask = Task {
                        do {
                            let notification = NSUserNotification()
                            notification.title = "Streaming TTS"
                            notification.informativeText = "Starting streaming synthesis: \(copiedText.prefix(50))\(copiedText.count > 50 ? "..." : "")"
                            NSUserNotificationCenter.default.deliver(notification)
                            
                            // Stream audio using single API call for all text at once
                            try await streamingPlayer.playText(copiedText, audioCollector: audioCollector)
                            
                            // Check if task was cancelled
                            if Task.isCancelled {
                                return
                            }
                            
                            let completionNotification = NSUserNotification()
                            completionNotification.title = "Streaming TTS Complete"
                            completionNotification.informativeText = "Finished streaming selected text"
                            NSUserNotificationCenter.default.deliver(completionNotification)
                            
                        } catch is CancellationError {
                            print("🛑 Audio streaming was cancelled")
                        } catch {
                            print("❌ Streaming TTS Error: \(error)")
                            
                            let errorNotification = NSUserNotification()
                            errorNotification.title = "Streaming TTS Error"
                            errorNotification.informativeText = "Failed to stream text: \(error.localizedDescription)"
                            NSUserNotificationCenter.default.deliver(errorNotification)
                            
                            // Note: Text is already in clipboard from Cmd+C, no need to copy again
                            let fallbackNotification = NSUserNotification()
                            fallbackNotification.title = "Text Ready in Clipboard"
                            fallbackNotification.informativeText = "Streaming failed, selected text copied via Cmd+C"
                            NSUserNotificationCenter.default.deliver(fallbackNotification)
                        }
                        
                        // Reset playing state when task completes (normally or via cancellation)
                        DispatchQueue.main.async {
                            self?.isCurrentlyPlaying = false
                            self?.currentStreamingTask = nil
                        }
                        
                        // Restore original clipboard contents after streaming
                        DispatchQueue.main.async {
                            pasteboard.clearContents()
                            for (type, data) in savedItems {
                                pasteboard.setData(data, forType: type)
                            }
                            print("♻️ Restored original clipboard contents")
                        }
                    }
                } else {
                    let notification = NSUserNotification()
                    notification.title = "Selected Text Copied"
                    notification.informativeText = "Streaming TTS not available, text copied to clipboard: \(copiedText.prefix(100))\(copiedText.count > 100 ? "..." : "")"
                    NSUserNotificationCenter.default.deliver(notification)
                    
                    // Don't restore clipboard in this case since user might want the copied text
                }
            } else {
                print("⚠️ No text was copied - nothing selected or copy failed")
                
                let notification = NSUserNotification()
                notification.title = "No Text Selected"
                notification.informativeText = "Please select some text first before using TTS"
                NSUserNotificationCenter.default.deliver(notification)
                
                // Restore clipboard since copy attempt failed
                pasteboard.clearContents()
                for (type, data) in savedItems {
                    pasteboard.setData(data, forType: type)
                }
                print("♻️ Restored clipboard after failed copy")
            }
        }
    }
    
    func updateStatusBarWithLevel(db: Float) {
        // Don't update status bar if screen recording is active
        if screenRecorder.recording {
            return
        }

        if let button = statusItem.button {
            button.image = nil
            button.title = "🟢" // Green dot while recording
        }
    }

    func showContinueModeIndicator() {
        if let button = statusItem.button {
            button.image = nil
            button.title = "🟡" // Yellow dot in continue mode
        }
    }
    
    func startTranscriptionIndicator() {
        // Don't update status bar if screen recording is active
        if screenRecorder.recording {
            return
        }

        // Show blue dot for processing
        if let button = statusItem.button {
            button.image = nil
            button.title = "🔵"
        }
    }
    
    func stopTranscriptionIndicator() {
        // Don't update status bar if screen recording is active
        if screenRecorder.recording {
            return
        }

        // Reset to default icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }
    }

    func startVideoProcessingIndicator() {
        // Show blue dot for video processing
        if let button = statusItem.button {
            button.image = nil
            button.title = "🔵"
        }
    }

    func stopVideoProcessingIndicator() {
        // Reset to default icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }
    }
    

    
    func showTranscriptionNotification(_ text: String) {
        let notification = NSUserNotification()
        notification.title = "Transcription Complete"
        notification.informativeText = text
        notification.subtitle = "Pasted at cursor"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func showTranscriptionError(_ message: String) {
        let notification = NSUserNotification()
        notification.title = "Transcription Error"
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func pasteTextAtCursor(_ text: String) {
        guard !text.isEmpty else {
            print("❌ pasteTextAtCursor: empty text, returning")
            return
        }

        print("📝 pasteTextAtCursor called with: \(text.prefix(50))...")

        // Check accessibility permission
        let trusted = AXIsProcessTrusted()
        print("🔐 AXIsProcessTrusted = \(trusted)")
        if !trusted {
            print("❌ Accessibility NOT granted - paste may fail")
        }

        // First try: Accessibility API (preferred method)
        print("🔄 Trying Accessibility API insert...")
        if insertTextViaAccessibility(text) {
            print("✅ Inserted via Accessibility API")
            return
        }

        // Fallback: Clipboard + Cmd+V
        print("⚠️ Accessibility insert failed, falling back to clipboard paste")
        pasteViaClipboard(text)
        print("📋 pasteViaClipboard completed")
    }

    func insertTextViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard error == .success, let element = focusedElement else {
            print("⚠️ No focused text element found (error: \(error.rawValue))")
            return false
        }

        // AXUIElement is a CFTypeRef, so we can use it directly
        let axElement = element as! AXUIElement

        let cfText = text as CFTypeRef
        let setError = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            cfText
        )

        if setError != .success {
            print("⚠️ Accessibility insertion failed: \(setError.rawValue)")
            return false
        }

        return true
    }

    func pasteViaClipboard(_ text: String) {
        // Use saved target app from when recording started
        let targetApp = targetAppBeforeRecording ?? NSWorkspace.shared.frontmostApplication

        // Check if we have Accessibility permission for auto-paste
        let hasAccessibility = AXIsProcessTrusted()

        let pasteboard = NSPasteboard.general

        // Only save/restore clipboard if we can auto-paste
        var savedItems: [NSPasteboard.PasteboardType: Data] = [:]
        if hasAccessibility {
            let savedTypes = pasteboard.types ?? []
            for type in savedTypes {
                if let data = pasteboard.data(forType: type) {
                    savedItems[type] = data
                }
            }
        }

        // Set our text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if !hasAccessibility {
            // No Accessibility - just leave text on clipboard for manual paste
            print("📋 Text copied to clipboard - press Cmd+V to paste")
            showTranscriptionNotification("📋 Copied! Press Cmd+V to paste")
            return
        }

        // Activate target app
        print("🎯 Target app: \(targetApp?.localizedName ?? "nil") (bundleID: \(targetApp?.bundleIdentifier ?? "nil"))")
        print("🎯 Activating target app...")
        targetApp?.activate(options: .activateIgnoringOtherApps)
        usleep(150000) // 150ms - give app time to activate

        // Send Cmd+V
        print("📤 Sending Cmd+V...")
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("❌ Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(10000) // 10ms between key down and up
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)

        print("✅ Cmd+V sent to \(targetApp?.localizedName ?? "unknown")")

        // Restore clipboard after short delay (only if we auto-pasted)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            pasteboard.clearContents()
            for (type, data) in savedItems {
                pasteboard.setData(data, forType: type)
            }
        }
    }
    
    func showHistoryForPasteFailure() {
        // When paste fails in certain apps, show the history window
        // by simulating the Command+Option+A keyboard shortcut
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code for 'A' is 0x00
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false) else {
            print("❌ Failed to create CGEvent for Cmd+Opt+A - Accessibility permission required")
            return
        }

        keyDown.flags = [.maskCommand, .maskAlternate]
        keyUp.flags = [.maskCommand, .maskAlternate]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        print("📚 Showing history window for paste failure recovery")
    }

    // MARK: - GeminiAudioRecordingManagerDelegate

    func audioLevelDidUpdate(db: Float) {
        updateStatusBarWithLevel(db: db)
    }

    func transcriptionDidStart() {
        startTranscriptionIndicator()
    }

    func transcriptionDidComplete(text: String) {
        stopTranscriptionIndicator()
        pasteTextAtCursor(text)
        showTranscriptionNotification(text)
    }

    func transcriptionDidFail(error: String) {
        stopTranscriptionIndicator()
        showTranscriptionError(error)
    }

    func recordingWasCancelled() {
        stopTranscriptionIndicator()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }

        let notification = NSUserNotification()
        notification.title = "Recording Cancelled"
        notification.informativeText = "Recording was cancelled"
        NSUserNotificationCenter.default.deliver(notification)
    }

    func recordingWasSkippedDueToSilence() {
        stopTranscriptionIndicator()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }

        let notification = NSUserNotification()
        notification.title = "Recording Skipped"
        notification.informativeText = "Audio was too quiet to transcribe"
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - OpenAIAudioRecordingManagerDelegate

    func openAIAudioLevelDidUpdate(db: Float) {
        updateStatusBarWithLevel(db: db)
    }

    func openAITranscriptionDidStart() {
        startTranscriptionIndicator()
    }

    func openAITranscriptionDidReceiveDelta(delta: String) {
        // Could update UI to show streaming progress if desired
        print(delta, terminator: "")
    }

    func openAITranscriptionDidComplete(text: String) {
        print("📋 openAITranscriptionDidComplete called with: \(text.prefix(50))...")
        stopTranscriptionIndicator()
        pasteTextAtCursor(text)
        showTranscriptionNotification(text)
    }

    func openAITranscriptionDidFail(error: String) {
        stopTranscriptionIndicator()
        showTranscriptionError(error)
    }

    func openAIRecordingWasCancelled() {
        stopTranscriptionIndicator()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }

        let notification = NSUserNotification()
        notification.title = "OpenAI Recording Cancelled"
        notification.informativeText = "Recording was cancelled"
        NSUserNotificationCenter.default.deliver(notification)
    }

    func openAIRecordingWasSkippedDueToSilence() {
        stopTranscriptionIndicator()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }

        let notification = NSUserNotification()
        notification.title = "Recording Skipped"
        notification.informativeText = "Audio was too quiet to transcribe"
        NSUserNotificationCenter.default.deliver(notification)
    }

}

// Safe bundle accessor that doesn't crash if bundle is missing
func findResourceBundle() -> Bundle? {
    let bundleName = "SuperVoiceAssistant_SuperVoiceAssistant"
    let candidates = [
        Bundle.main.resourceURL,
        Bundle(for: AppDelegate.self).resourceURL,
        Bundle.main.bundleURL,
        Bundle.main.executableURL?.deletingLastPathComponent()
    ]
    for candidate in candidates {
        if let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle"),
           let bundle = Bundle(url: bundlePath) {
            return bundle
        }
    }
    return nil
}

// Create and run the app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular) // Show in dock and cmd+tab

// Set the app icon from our custom ICNS file (safe - won't crash if bundle missing)
if let resourceBundle = findResourceBundle(),
   let iconURL = resourceBundle.url(forResource: "AppIcon", withExtension: "icns"),
   let iconImage = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = iconImage
}

app.run()
