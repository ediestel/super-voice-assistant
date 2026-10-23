# Voice Commands and Trackpad Gestures

Two optional ways to control the **OpenAI recording** (Cmd+Option+V) without the
keyboard. Both are off by default and switched on in **Settings** (right-click the menu-bar icon →
Settings…).

They apply only to the OpenAI recording. They do not control conversation mode, the Apple Speech
panel, Gemini recording or screen recording.

## Voice commands

### Requirements

- `OPENAI_API_KEY` (the commands are read from the live OpenAI transcript).
- Settings → **Voice Commands** → **Enable voice commands during recording**.

### What you can say

While an OpenAI recording runs, the app watches the last few seconds of the live transcript
(about 150 characters) for these phrases:

| Say | Effect |
|---|---|
| "stop", "stop recording", "halt recording", "finish recording" | stops and transcribes (like double-tapping Space) |
| "done", "done recording", "that's all", "end recording" | stops and transcribes (like double-tapping Space) |
| "cancel", "cancel recording", "discard", "discard recording" | discards the recording (like Escape) |
| "pause", "pause recording", "hold on" | recognised, but **does nothing** (pause is not implemented) |
| "continue", "continue recording", "resume", "resume recording", "keep going" | starts the next recording only in continue mode; since nothing is recorded in continue mode, in practice use **Space** |

After a command, further commands are ignored for 2 seconds.

### Removing the command from the text

**Remove voice commands from final transcription** deletes the command phrase from the text
before it is pasted.

> The switch shows as on from the start, but the recording reads the setting as **off** until it
> has been saved once. To make removal work, switch it off and on again one time.

### Know before you use it

- **Matching is by letters, not whole words.** "stop" also fires inside "stopped" or
  "nonstop", "done" inside "abandoned", "cancel" inside "cancelled". Dictating such a word ends
  or discards your recording. Use voice commands for short notes, not for prose containing these
  words.
- **Removal is not limited to the command.** With removal on, every whole word or phrase from the
  table above is deleted from the entire transcript, for example "continue", "resume", "done",
  "stop", "hold on" in the middle of a sentence.
- The live transcript arrives with a short delay, so a command takes effect a moment after you
  say it.
- The phrases are English.

### Example

1. Cursor in a text field, **Cmd+Option+V**.
2. "Buy milk and bread, stop recording."
3. The recording stops; "Buy milk and bread," is pasted (with removal in effect).

## Trackpad gestures (experimental)

### Requirements

- Settings → **Trackpad Gestures** → **Enable trackpad gesture controls**.
- Accessibility permission.

### Gestures

| Gesture | Intended effect | State |
|---|---|---|
| Three-finger swipe down | start an OpenAI recording | see limits |
| Three-finger swipe up | stop and transcribe | see limits |
| Force click (press until the second click) | start / stop | see limits |
| Four-finger tap | cancel | **not detected** — there is no code that recognises it |

### Limits — why gestures rarely work

- The app listens for gestures with **local** event monitors, which only receive events while one
  of the app's own windows (Settings, History, the Apple Speech panel) is in front. The app is a
  menu-bar app with no main window, so while you work in another app the gestures are not seen.
- Three-finger swipes reach apps only as swipe events when macOS does not use them itself
  (System Settings → Trackpad → More Gestures; three-finger swipes are normally taken by Mission
  Control, App Exposé and switching spaces).
- Magic Mouse support exists in the code but is never switched on.

Use the keyboard (Cmd+Option+V, double-tap Space, Escape) or a left-click on the menu-bar icon for reliable
control.

## Settings reference

| Setting | Stored as (UserDefaults) | Default |
|---|---|---|
| Enable voice commands during recording | `voiceCommandsEnabled` | off |
| Remove voice commands from final transcription | `removeVoiceCommandsFromTranscription` | shown on, in effect off until toggled once |
| Enable trackpad gesture controls | `gestureControlsEnabled` | off |

## Troubleshooting

**A command does nothing**
- Is the switch on in Settings, and was the recording started with Cmd+Option+V (not Gemini,
  not conversation mode)?
- Say the phrase clearly at the end of a sentence; wait a moment.
- "pause" and "hold on" do nothing by design (not implemented).

**The recording stopped by itself**
- A word containing "stop", "done", "cancel" or "discard" was dictated. Turn voice commands off
  for longer dictation.

**Words are missing from the pasted text**
- Removal deleted command words in the text. Switch off **Remove voice commands from final
  transcription**.

**Gestures do nothing**
- Expected while another app is in front (see Limits). Check that the switch is on and that no
  system gesture uses three fingers.

## Where it lives in the code

- `SharedSources/VoiceCommandDetector.swift` — phrases, matching window, cooldown, removal.
- `Sources/OpenAIAudioRecordingManager.swift` — feeds transcript deltas to the detector, maps
  commands to stop / cancel / continue, implements the gesture delegate.
- `Sources/GestureEventHandler.swift` — local swipe and pressure monitors.
- `Sources/SettingsWindow.swift` — the switches.

See also [implementation-summary-voice-gestures.md](implementation-summary-voice-gestures.md).
