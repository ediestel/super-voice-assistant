# Claude Development Notes for Super Voice Assistant

## Project Guidelines

- Follow the roadmap and tech choices outlined in README.md

## Background Process Management

- When developing and testing changes, run the app in background using: `swift build && swift run SuperVoiceAssistant` with `run_in_background: true`
- Keep the app running in background while the user tests functionality
- Only kill and restart the background instance when making code changes that require a fresh build
- Allow the user to continue using the running instance between agent sessions
- The user prefers to keep the app running for continuous testing

## Git Commit Guidelines

- Never include Claude attribution or Co-Author information in git commits
- Keep commit messages clean and professional without AI-related references

## Completed Features

### Voice Commands and Trackpad Gestures

**Status**: Voice commands work (with false triggers, see below); gestures are wired but rarely fire
**Documentation**: See `docs/voice-commands-and-gestures.md` and `docs/implementation-summary-voice-gestures.md` (current state and known gaps)
**Key Files**:
- `SharedSources/VoiceCommandDetector.swift` - Real-time voice command detection
- `Sources/GestureEventHandler.swift` - Trackpad gesture monitoring
- `Sources/OpenAIAudioRecordingManager.swift` - Integration with recording manager
- `Sources/SettingsWindow.swift` - Settings UI for enabling/configuring features

**Features**:
- ✅ Voice command detection during recording ("stop recording", "cancel recording", etc.)
- ✅ Optional command removal from final transcription
- ⚠️ Three-finger swipe gestures for start/stop recording (local monitor: only while an app window is key)
- ⚠️ Force touch gesture for toggle recording (same limit)
- ❌ Four-finger tap cancel: listed in Settings, not detected
- ✅ Settings UI for enabling and configuring both features
- ✅ Accessibility permission support for gestures
- ✅ Cooldown mechanisms to prevent duplicate triggers

**Voice Commands**:
- "stop recording" / "done recording" - Stops recording and transcribes
- "cancel recording" / "discard recording" - Cancels without saving
- "continue recording" / "resume recording" - Starts new recording (in continue mode)

**Trackpad Gestures**:
- Three-finger swipe down: Start recording
- Three-finger swipe up: Stop recording
- Force touch: Toggle recording

**Implementation Notes**:
- Voice commands work by monitoring real-time transcription deltas (substring match: "stopped" triggers "stop")
- `removeVoiceCommandsFromTranscription` reads false until toggled once (AppStorage default is not registered)
- Gestures use NSEvent local monitoring (work when app is active)
- Both integrate seamlessly with existing keyboard shortcuts
- Settings stored in UserDefaults (voiceCommandsEnabled, gestureControlsEnabled)

## Completed Features

### Gemini Live TTS Integration

**Status**: ✅ Complete and integrated into main app
**Key Files**:
- `SharedSources/GeminiStreamingPlayer.swift` - Streaming TTS playback engine
- `SharedSources/GeminiAudioCollector.swift` - Audio collection and WebSocket handling
- `SharedSources/SmartSentenceSplitter.swift` - Text processing for optimal speech

**Features**:
- ✅ Cmd+Opt+S keyboard shortcut for reading selected text aloud
- ✅ Sequential streaming for smooth, natural speech with minimal latency
- ✅ Smart sentence splitting for optimal speech flow
- ✅ 15% speed boost via TimePitch effect

### Gemini Audio Transcription

**Status**: ✅ Complete and integrated into main app
**Branch**: `gemini-audio-feature`
**Key Files**:
- `SharedSources/GeminiAudioTranscriber.swift` - Gemini API audio transcription
- `Sources/GeminiAudioRecordingManager.swift` - Audio recording manager for Gemini

**Features**:
- ✅ Gemini audio recording and transcription (menu bar item; Cmd+Opt+X shortcut disabled by default)
- ✅ Cloud-based transcription using Gemini 2.5 Flash API
- ✅ WAV audio conversion and base64 encoding
- ✅ Silence detection and automatic filtering
- ✅ Mutual exclusion with OpenAI recording and screen recording
- ✅ Transcription history integration

**Keyboard Shortcuts**:
- **Cmd+Opt+X**: Gemini audio recording (cloud) — disabled by default (commented out in `main.swift`); menu bar item still works
- **Cmd+Opt+S**: Text-to-speech with Gemini
- **Cmd+Opt+C**: Screen recording with video transcription
- **Cmd+Opt+A**: Show transcription history
- **Fn+Ctrl+Option**: Hands-free conversation mode (Apple Speech, on-device; Return after 7 s of silence)
- **Fn+Ctrl+Option+Cmd**: Hands-free dictation mode (same engine, never presses Return)
- **Menu bar → Apple Speech Panel**: Apple Speech (Native) floating panel — voice to CLI (no shortcut)
- **Cmd+Opt+V**: OpenAI Realtime audio recording (cloud, primary)

**During OpenAI Recording**:
- **Space**: Stop recording and transcribe
- **Escape**: Cancel recording (discard)

**After OpenAI Transcription (Continue Mode)**:
- **Space**: Start new recording
- **Escape**: Exit continue mode

### OpenAI Realtime Transcription

**Status**: ✅ Complete and integrated into main app
**Key Files**:
- `SharedSources/OpenAIRealtimeTranscriber.swift` - WebSocket-based realtime transcription
- `Sources/OpenAIAudioRecordingManager.swift` - Audio recording manager for OpenAI

**Features**:
- ✅ Cmd+Opt+V keyboard shortcut for OpenAI audio recording
- ✅ Real-time streaming transcription via WebSocket
- ✅ Space bar to stop recording (easier than key combo)
- ✅ Space bar continue mode (start new recording after transcription)
- ✅ Escape to cancel recording or exit continue mode
- ✅ Auto-paste transcription at cursor position
- ✅ Server-side VAD (voice activity detection)
- ✅ Manual audio buffer commit on stop for reliable transcription

### Auto-Paste Functionality

**Status**: ✅ Working
**Key Files**:
- `Sources/main.swift` - `pasteTextAtCursor()`, `insertTextViaAccessibility()`, `pasteViaClipboard()`

**Requirements**:
- ⚠️ **Accessibility Permission Required**: Add the app to System Settings → Privacy & Security → Accessibility
- Without this permission, both Accessibility API insert and CGEvent-based paste will fail

**Paste Methods** (in order of preference):
1. Accessibility API (`AXUIElementSetAttributeValue`) - direct text insertion
2. Clipboard + Cmd+V (fallback) - copies to clipboard and simulates paste

### Apple Speech (Native) — Voice to CLI

**Status**: ✅ Complete and integrated into main app
**Key Files**:
- `SharedSources/AppleSpeechTranscriber.swift` - SFSpeechRecognizer + AVAudioEngine live-dictation wrapper (public API, in `SharedModels`)
- `Sources/AppleSpeechManager.swift` - NSPanel-hosted manager singleton + `AppleSpeechView` SwiftUI UI
- `Sources/Info.plist` - `NSSpeechRecognitionUsageDescription` + `NSMicrophoneUsageDescription` (embedded via `-sectcreate` linker flag)
- `Sources/main.swift` - `handleMenuAppleSpeech` ("Apple Speech Panel" menu item); the former Ctrl+Space shortcut was removed
- `Sources/SettingsWindow.swift` - "Apple Speech (Native)" GroupBox + menu bar row
- `Sources/ConversationMode.swift` - hands-free conversation and dictation modes + `FnControlOptionHotkey` (Fn+Ctrl+Option, Fn+Ctrl+Option+Cmd)

**Features**:
- ✅ "Apple Speech Panel" menu item opens a floating panel; Start / ⌘M begins on-device dictation
- ✅ Fn+Ctrl+Option conversation mode types words live into the focused field and sends each turn with Return after 7 s of silence
- ✅ Fn+Ctrl+Option+Cmd dictation mode types words live but never presses Return; a pause only starts a fresh recognition segment
- ✅ Real-time word-by-word streaming into an editable `TextEditor`
- ✅ Start/Stop (or ⌘M) toggle, Clear, and Send to CLI (Enter) controls
- ✅ Pastes the (optionally edited) transcript at the cursor via `AppDelegate.pasteTextAtCursor()`
- ✅ Floating panel survives Mission Control space switches (`.canJoinAllSpaces`)
- ✅ Permission-denied / recognizer-unavailable errors surfaced in the panel status bar

**Implementation Notes**:
- `AppleSpeechTranscriber` lives in `SharedModels`, so its protocol/class/init are `public`
- The transcriber dispatches all delegate callbacks to the main thread
- Info.plist is embedded into the executable via Package.swift `linkerSettings`
  (`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/Info.plist`)
  and excluded from the target's source set
- Requires Speech Recognition + Microphone permission (System Settings → Privacy & Security)
- `startListening()` throws `AppleSpeechError.audioInputUnavailable` when the input format is 0 Hz / 0 channels
  (input device changing, e.g. sleep/wake); `installTap` would otherwise raise an uncatchable NSException

## Fred Intelligence

This repository has Fred-generated intelligence data in `.fred/`.
See `.fred/CLAUDE.md` for file labels and dependency analysis.
