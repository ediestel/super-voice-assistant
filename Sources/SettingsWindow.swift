import Cocoa
import SwiftUI
import SharedModels

@MainActor
struct SettingsView: View {
    @State private var geminiApiKey: String = ""
    @State private var openaiApiKey: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Super Voice Assistant Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Configure your API keys and preferences")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            // Settings content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // API Keys Section
                    GroupBox(label: Label("API Keys", systemImage: "key")) {
                        VStack(alignment: .leading, spacing: 12) {
                            // Gemini API Key Status
                            HStack {
                                Image(systemName: geminiApiKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundColor(geminiApiKey.isEmpty ? .red : .green)
                                Text("Gemini API Key")
                                Spacer()
                                Text(geminiApiKey.isEmpty ? "Not configured" : "Configured")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }

                            // OpenAI API Key Status
                            HStack {
                                Image(systemName: openaiApiKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundColor(openaiApiKey.isEmpty ? .red : .green)
                                Text("OpenAI API Key")
                                Spacer()
                                Text(openaiApiKey.isEmpty ? "Not configured" : "Configured")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }

                            Text("API keys are read from the .env file in the app directory.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                        .padding(8)
                    }

                    // Keyboard Shortcuts Section
                    GroupBox(label: Label("Keyboard Shortcuts", systemImage: "keyboard")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ShortcutRow(shortcut: "Cmd+Opt+Z", description: "OpenAI audio recording")
                            ShortcutRow(shortcut: "Cmd+Opt+X", description: "Gemini audio recording")
                            ShortcutRow(shortcut: "Cmd+Opt+S", description: "Read selected text aloud")
                            ShortcutRow(shortcut: "Cmd+Opt+C", description: "Screen recording")
                            ShortcutRow(shortcut: "Cmd+Opt+A", description: "Show transcription history")
                        }
                        .padding(8)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Spacer()

                Button("Done") {
                    NSApplication.shared.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .onAppear {
            // Load API key status from environment
            geminiApiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
            openaiApiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        }
    }
}

struct ShortcutRow: View {
    let shortcut: String
    let description: String

    var body: some View {
        HStack {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
            Text(description)
                .foregroundColor(.secondary)
        }
    }
}

class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let hostingController = NSHostingController(rootView: SettingsView())
        window.contentViewController = hostingController

        self.init(window: window)
    }

    func showWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
