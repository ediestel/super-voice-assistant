# Implementation Notes: Voice Commands & Trackpad Gestures

Added 2026-02-06; this file describes the code as it stands (checked 2026-10-23), including what
does not work. User documentation: [voice-commands-and-gestures.md](voice-commands-and-gestures.md).

## Status

| Part | State |
|---|---|
| Voice command detection during OpenAI realtime recording | works, with false triggers (substring matching) |
| Stop / done / cancel commands | work |
| Continue command | wired, but cannot fire in practice (no transcript in continue mode) |
| Pause command | detected, no action |
| Command removal from the transcript | works once the setting has been saved; removes every alias in the whole text |
| Three-finger swipe up/down, force click | wired; events arrive only while an app window is key |
| Four-finger tap | delegate method exists, nothing detects the gesture |
| Magic Mouse gestures | `enableMagicMouseGestures()` exists, never called |
| Global (system-wide) gesture monitoring | `startGlobalMonitoring()` only calls the local monitor |

## Voice commands

**File:** `SharedSources/VoiceCommandDetector.swift` (target `SharedModels`, public API).

- `Command` enum with aliases, checked in this order: stop, cancel, pause, resume, done.
  - stop: "stop", "stop recording", "halt recording", "finish recording"
  - cancel: "cancel", "cancel recording", "discard", "discard recording"
  - pause: "pause", "pause recording", "hold on"
  - resume: "continue", "continue recording", "resume", "resume recording", "keep going"
  - done: "done", "done recording", "that's all", "end recording"
- `processDelta(_:)` appends each realtime transcript delta to `recentTranscription` and keeps
  the last `commandWindowSeconds * 50` = 150 characters.
- `detectCommands()` lowercases that window and tests `text.contains(alias)` — a **substring**
  test, so aliases fire inside longer words ("stopped", "abandoned" → "done", "cancelled").
  On a hit it calls `onCommandDetected(command, alias)`, clears the window and blocks further
  detections for `commandCooldown` = 2 s.
- `minimumConfidence` and `isEnabled` exist; `minimumConfidence` is not used.
- `removeCommandText(from:)` removes **every alias** (longest first, case-insensitive,
  `\b…\b` word boundaries) from the whole transcription and collapses spaces. It does not know
  which phrase was actually spoken as a command.

**Integration:** `Sources/OpenAIAudioRecordingManager.swift`

- `voiceCommandsEnabled` reads `UserDefaults.bool(forKey: "voiceCommandsEnabled")`; deltas are
  passed to the detector only when it is true (around line 224).
- `setupVoiceCommands()`: stop/done → `stopRecording()`; cancel → `cancelRecording()`;
  pause → log only; resume → `handleSpaceContinue()` if the state is `.continueMode`.
  In continue mode no audio is streamed and no deltas arrive, so resume cannot trigger.
- Removal is applied to the final text and to the fallback text when
  `UserDefaults.bool(forKey: "removeVoiceCommandsFromTranscription")` is true. The Settings toggle
  uses `@AppStorage(... ) = true`, which shows *on* without writing the key, so `bool(forKey:)`
  returns false until the user toggles it once.

**Not covered:** Gemini recording, screen recording, conversation mode and the Apple Speech panel
do not use the detector.

## Trackpad gestures

**File:** `Sources/GestureEventHandler.swift` (singleton `GestureEventHandler.shared`).

- `startMonitoring()` installs `NSEvent.addLocalMonitorForEvents` for `.swipe` and for
  `.pressure`/`.gesture`. Local monitors only see events dispatched to this app, i.e. while one
  of its windows is key. The app runs with activation policy `.accessory` (menu-bar only), so
  during normal use in other apps no events arrive.
- Swipe: vertical when `|deltaY| > |deltaX|` and `|deltaY| > 0.1`; `deltaY > 0` → swipe up
  (stop), `< 0` → swipe down (start). `.swipe` events are only delivered for swipes macOS itself
  does not consume (three-finger swipes are usually taken by Mission Control / spaces).
- Pressure: `event.stage == 2` (force click) → `handleForceTouch()` with a 1 s cooldown.
- `GestureEventDelegate.handleFourFingerTap()` is implemented by the recording manager
  (cancel), but no code produces it.
- `startGlobalMonitoring()` prints a warning and calls `startMonitoring()`.
- `enableMagicMouseGestures()` (scroll-wheel based) is never called.

**Integration:** the recording manager is the delegate (`setupGestureControls()`); when
`gestureControlsEnabled` is true it calls `startMonitoring()` once an OpenAI recording has started.
The Settings toggle also starts/stops monitoring directly.
Swipe down → `startRecording()` if `canStart(.openai)`; swipe up → `stopRecording()` if an OpenAI
recording is active; force click → `toggleRecording()`.

## Settings

`Sources/SettingsWindow.swift`, stored in `UserDefaults.standard`:

| Key | UI default | Effective default |
|---|---|---|
| `voiceCommandsEnabled` | off | off |
| `removeVoiceCommandsFromTranscription` | on | off until toggled once |
| `gestureControlsEnabled` | off | off |

## Tests

`swift run TestVoiceCommands` (`tests/test-voice-commands/`) exercises detection and removal of
the detector in isolation. There are no automated tests for gestures.

## Fixes worth making

1. Match aliases on word boundaries (as removal already does) and prefer the phrase at the end of
   the window, to stop false triggers.
2. Remove only the alias that triggered, at the position it was detected.
3. Register `removeVoiceCommandsFromTranscription` with `UserDefaults.register(defaults:)` so the
   UI and the behaviour agree.
4. Drop or implement pause and resume; drop the four-finger tap from the UI or detect it.
5. Use a global monitor (`addGlobalMonitorForEvents`) for gestures, or remove the feature from
   Settings.
