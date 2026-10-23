# Super Voice Assistant

A macOS menu-bar app that turns speech into text wherever your cursor is, reads selected text
aloud, and transcribes screen recordings with what is on screen as context.

It works **without any API key**: on-device Apple Speech gives you hands-free conversation mode
and a dictation panel, and nothing leaves your Mac. An OpenAI key and a Gemini key are
**optional**; each one adds its own cloud features (see the table below).

## Demo

**Instant text-to-speech:**

https://github.com/user-attachments/assets/c961f0c6-f3b3-49d9-9b42-7a7d93ee6bc8

**Visual disambiguation for names:**

https://github.com/user-attachments/assets/0b7f481f-4fec-4811-87ef-13737e0efac4

## What works with which key

| Feature | How to start it | Needs | Where the audio goes |
|---|---|---|---|
| Conversation mode (hands-free, live dictation) | **Fn+Ctrl+Option** or menu | nothing | stays on your Mac (on-device Apple Speech where your language supports it) |
| Apple Speech panel (live dictation, edit, send) | menu → **Apple Speech Panel** | nothing | stays on your Mac (as above) |
| History, Statistics, Audio Devices, Settings | **Cmd+Option+A** or menu | nothing | local |
| OpenAI transcription (cloud) | **Cmd+Option+V**, or left-click the menu-bar icon | `OPENAI_API_KEY` | OpenAI, model `gpt-4o-transcribe` |
| Voice commands ("stop recording" …) | during Cmd+Option+V recording | `OPENAI_API_KEY` | OpenAI |
| Gemini audio transcription | menu → **Gemini Recording** | `GEMINI_API_KEY` | Google, model `gemini-2.5-flash` |
| Read selected text aloud | **Cmd+Option+S** | `GEMINI_API_KEY` | Google, Gemini Live native-audio model |
| Screen recording + transcription | **Cmd+Option+C** | `GEMINI_API_KEY` and `ffmpeg` | Google, model `gemini-2.5-flash` (video with sound) |

Transcription is real-time in both cases. Apple Speech types or shows the words while you
speak. OpenAI streams the audio while you speak, and pastes the text when you stop.

Without a key the app starts normally. Settings shows which keys are configured. A feature
whose key is missing fails with a message naming the missing key; the rest keeps working.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel
- Xcode 15+ or the Xcode Command Line Tools (Swift 5.9+) to build it
- Optional: an OpenAI API key, a Gemini API key
- Optional: `ffmpeg` (`brew install ffmpeg`), only for screen recording

## Install

Full guide, including the app bundle, permissions and troubleshooting:
**[INSTALLATION.md](INSTALLATION.md)**. In short:

```bash
git clone https://github.com/ediestel/super-voice-assistant.git
cd super-voice-assistant

# Build the app bundle (release, universal) and install it
./scripts/build_app_bundle.sh
cp -R build/SuperVoiceAssistant.app /Applications/
open /Applications/SuperVoiceAssistant.app
```

Then grant **Accessibility** (needed for the global shortcuts and for pasting), and allow
**Microphone** and **Speech Recognition** when macOS asks. Optional keys go in `~/.env`:

```bash
# only the lines for the services you want
echo "OPENAI_API_KEY=sk-..."   >> ~/.env
echo "GEMINI_API_KEY=AIza..."  >> ~/.env
```

Restart the app after adding or changing a key; keys are read at start.

## Using it

The app lives in the menu bar as a **microphone** icon (no Dock icon). While conversation mode
is on, the icon turns into a filled waveform circle; while recording, a blinking status shows
next to it.

- **Right-click** the icon for the menu.
- **Left-click** the icon starts or stops the main cloud recording (OpenAI): it stops a running
  screen recording or recording first, leaves continue mode, and otherwise starts a new
  OpenAI recording. Without an OpenAI key, use the menu.

### The menu

| Item | What it does |
|---|---|
| ▶ Start Recording | OpenAI recording (same as Cmd+Option+V) |
| Gemini Recording | Start / stop a Gemini audio recording |
| Screen Recording (⌘⌥C) | Start / stop a screen recording that is then transcribed |
| Read Selected Text (⌘⌥S) | Read the selected text aloud / stop reading |
| Conversation Mode (fn⌃⌥) | Hands-free dictation on / off |
| Apple Speech Panel | Floating dictation panel |
| History (⌘⌥A) | Past transcriptions |
| Settings… / Statistics… | The manager window with its tabs |
| Test Auto-Paste | Pastes a test text at the cursor, to check the Accessibility grant |
| Quit | Quits the app |

### Conversation mode — real-time and hands-off, no key needed

For talking to a chat window (an LLM, a messenger) without touching the keyboard.

1. Click into the text field you want to fill.
2. Press **Fn+Ctrl+Option** (a "Tink" sound plays). Speak; words are typed live into the field.
3. Pause: after **7 seconds** without new words the app presses **Return**, which sends the turn.
   It keeps listening for your next turn. The same three keys turn it off; Space plays no part.
4. Press **Fn+Ctrl+Option** while a turn is unsent to send it at once.
5. Press **Fn+Ctrl+Option** when nothing is typed to turn the mode off ("Pop" sound).

Recognition uses Apple Speech in your system language and runs on-device whenever that language
supports it. If the microphone becomes unavailable (for example while the input device changes
during sleep/wake), the mode turns itself off and shows a notification.

### Apple Speech panel — dictate, correct, then send

For dictating into a terminal or editor where you want to check the text first.

1. Menu → **Apple Speech Panel**. A floating panel opens and stays above other windows.
2. Press **Start** or **⌘M** and speak; words appear live in the text area.
3. Correct the text in the panel if needed. Plain Return makes a new line.
4. **⌘Return** or **Send to CLI** pastes the text at the cursor in the app you were using before.
   **Copy** puts it on the clipboard, **Clear** empties the panel. The panel stays open for the
   next dictation.

If permission is missing or recognition is unavailable, the panel's status line tells you where
to enable it (System Settings → Privacy & Security → Speech Recognition).

### OpenAI transcription (cloud)

1. Put the cursor where the text should go.
2. Press **Cmd+Option+V** (or left-click the icon) and speak. The audio streams to OpenAI as you
   talk.
3. **Double-tap Space** (two presses within 0.8 s) to stop and transcribe, or press **Escape** to
   discard. A single Space press does nothing, so you can keep typing spaces while recording.
4. The text is pasted at the cursor.
5. You are now in **continue mode**: **Space** starts the next recording, **Escape** leaves
   continue mode.

Optional voice commands and trackpad gestures can control this recording; see
[docs/voice-commands-and-gestures.md](docs/voice-commands-and-gestures.md).

### Gemini audio transcription

Menu → **Gemini Recording** starts recording; choose it again to stop and transcribe. **Escape**
cancels. The text is pasted at the cursor. Its shortcut Cmd+Option+X is switched off; to switch
it on, uncomment the `geminiAudioRecording` line in `Sources/main.swift` and rebuild.

### Read selected text aloud

Select text in any app and press **Cmd+Option+S**. The text is split into sentences and streamed
to Gemini Live, and the speech plays as it arrives, slightly faster than normal (1.15×). Press
**Cmd+Option+S** again to stop. The output device can be chosen in the Audio Devices tab.

### Screen recording with transcription

For dictating code, names and technical terms: Gemini sees the screen as well as hearing you,
so it can spell what is shown.

1. Press **Cmd+Option+C**. The menu bar shows **🎥 REC**.
2. Talk about what is on screen.
3. Press **Cmd+Option+C** again. The video (main screen with cursor, plus the default
   microphone, recorded with ffmpeg) is sent to Gemini, and the transcript is pasted at the
   cursor.
4. The video is saved on your Desktop as `screen-recording-<date>.mp4` and deleted after a
   successful transcription. If transcription fails, it stays there.

Only one recording runs at a time: screen recording, OpenAI and Gemini recordings and the Apple
Speech panel block one another, with a notification saying what is running.

### History, statistics, audio devices, settings

One window with four tabs, opened from the menu or with **Cmd+Option+A** (History):

- **Settings**: which API keys are configured, the shortcuts, switches for voice commands and
  trackpad gestures.
- **History**: past transcriptions, kept in `~/Documents/SuperVoiceAssistant/transcription_history.json`.
- **Statistics**: counts of your transcriptions, in `~/Documents/SuperVoiceAssistant/transcription_stats.json`.
- **Audio Devices**: choose the microphone and the playback device, or follow the system default.

### Text replacements

Fix words speech recognition keeps getting wrong. Create `config.json`:

```json
{
  "textReplacements": {
    "Cloud Code": "Claude Code",
    "cloud.md": "CLAUDE.md"
  }
}
```

Replacements are case-sensitive and apply to OpenAI, Gemini and screen-recording transcripts
(not to Apple Speech). The file is read from the **current working directory** at start: it works
when you run the app from the project folder (`swift run` or the `ccc` alias below), not when the
app is started from Finder or at login.

## Keyboard shortcuts

| Shortcut | Action | Needs |
|---|---|---|
| Fn+Ctrl+Option (the three keys together) | Conversation mode, hands-off: on / send turn now / off. No other key is involved | nothing |
| Cmd+Option+V | OpenAI recording | OpenAI key |
| Space twice / Escape | During OpenAI recording only: stop and transcribe / discard | |
| Space / Escape | In OpenAI continue mode only: next recording / leave continue mode | |
| Cmd+Option+S | Read selected text aloud / stop | Gemini key |
| Cmd+Option+C | Screen recording start / stop and transcribe | Gemini key, ffmpeg |
| Cmd+Option+A | History window | nothing |
| ⌘M, ⌘Return | In the Apple Speech panel: start/stop, send | nothing |

All global shortcuts need the Accessibility permission.

## Privacy

- Apple Speech features (conversation mode, panel) keep audio on the Mac when the language has an
  on-device model; otherwise macOS uses Apple's server recognition.
- OpenAI and Gemini features send the audio, the selected text or the screen video to that
  provider, only when you start them.
- Keys are read from `.env` files or the environment and are never written anywhere by the app.

## Running from source (developers)

```bash
swift build
swift run SuperVoiceAssistant
```

When run from the terminal, macOS attributes the permissions to the terminal app, so grant
Accessibility and Screen Recording to Terminal/iTerm2. Started this way the app still registers
itself as a login item.

Quick alias to start the debug build from anywhere (it finds the project's `.env` by walking up
from the executable):

```bash
echo 'alias ccc="$HOME/path/to/super-voice-assistant/.build/arm64-apple-macosx/debug/SuperVoiceAssistant"' >> ~/.zshrc
source ~/.zshrc
```

Test tools:

```bash
swift run TestAppleSpeech            # Apple Speech dictation
swift run TestOpenAITranscription    # OpenAI transcription
swift run TestStreamingTTS           # Gemini text-to-speech
swift run TestAudioCollector         # Gemini Live audio collection
swift run TestSentenceSplitter       # sentence splitting for TTS
swift run TestTextInserter           # pasting at the cursor
swift run TestVoiceCommands          # voice command detection
swift run RecordScreen               # 3-second screen capture
swift run TranscribeVideo <file.mp4> # Gemini video transcription
```

## Project structure

- `Sources/` — the app
  - `main.swift` — app delegate, menu, shortcuts, pasting, screen-recording flow
  - `ConversationMode.swift` — hands-free mode and the Fn+Ctrl+Option hotkey
  - `AppleSpeechManager.swift` — the Apple Speech panel
  - `OpenAIAudioRecordingManager.swift`, `GeminiAudioRecordingManager.swift` — cloud recordings
  - `ScreenRecorder.swift` — ffmpeg screen capture
  - `RecordingStateManager.swift` — one recording at a time
  - `UnifiedManagerWindow.swift`, `SettingsWindow.swift`, `TranscriptionHistory*.swift`,
    `TranscriptionStats.swift`, `StatsViewController.swift`, `AudioDevicesViewController.swift`
  - `TextReplacements.swift`, `GestureEventHandler.swift`, `KeyboardEventHandler.swift`
- `SharedSources/` — shared library (`SharedModels`)
  - `AppleSpeechTranscriber.swift`, `OpenAIRealtimeTranscriber.swift`, `OpenAIAudioTranscriber.swift`,
    `GeminiAudioTranscriber.swift`, `VideoTranscriber.swift`
  - `GeminiAudioCollector.swift`, `GeminiStreamingPlayer.swift`, `SmartSentenceSplitter.swift`
  - `TextInserter.swift`, `VoiceCommandDetector.swift`, `AudioDeviceManager.swift`,
    `AudioSessionManager.swift`, `EnvironmentLoader.swift`
- `tests/`, `tools/` — the test executables listed above
- `scripts/` — `build_app_bundle.sh` and icon scripts
- `docs/` — voice commands and gestures

## License

See [LICENSE](LICENSE).
