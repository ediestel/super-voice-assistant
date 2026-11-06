# Super Voice Assistant — Installation Guide

This guide takes you from a fresh clone to a working menu-bar app: build, install, permissions,
optional API keys, first test of every feature, and what to do when something does not work.

API keys are **optional**. Without any key you get conversation mode, dictation mode and the
Apple Speech panel (on-device dictation), history and settings. Each key adds features:

| Key | Adds |
|---|---|
| none | Conversation mode (Fn+Ctrl+Option), dictation mode (Fn+Ctrl+Option+Cmd) and Apple Speech panel, all real-time (words appear as you speak), in English or German (Fn+Ctrl+Option+L), history, statistics, audio devices |
| `OPENAI_API_KEY` | OpenAI transcription (Cmd+Option+V, left-click on the icon), voice commands |
| `GEMINI_API_KEY` | Read selected text aloud (Cmd+Option+S), screen recording transcription (Cmd+Option+C), Gemini audio recording |

## 1. Before you start

- macOS 14 (Sonoma) or later.
- Swift 5.9 or later: install Xcode 15+ from the App Store, or only the command line tools:
  ```bash
  xcode-select --install
  swift --version     # should print 5.9 or later
  ```
- Only for screen recording: ffmpeg.
  ```bash
  brew install ffmpeg
  which ffmpeg        # must print a path, e.g. /opt/homebrew/bin/ffmpeg
  ```
- Optional keys: an OpenAI API key (platform.openai.com) and/or a Gemini API key
  (aistudio.google.com).

## 2. Get the code

```bash
git clone https://github.com/ediestel/super-voice-assistant.git
cd super-voice-assistant
```

## 3. Build the app bundle

```bash
bash scripts/build_app_bundle.sh         # release, universal (arm64 + x86_64)
# or: bash scripts/build_app_bundle.sh debug
```

The script builds the `SuperVoiceAssistant` product, creates `build/SuperVoiceAssistant.app`
with its icon and Info.plist (menu-bar app, microphone and speech-recognition descriptions), and
signs it. If a certificate named **SuperVoice Local Signing** is in your keychain it signs with
that; otherwise it signs ad hoc. API keys are never copied into the bundle (see step 6).

> Ad-hoc signing ties the Accessibility grant to this one build. After every rebuild macOS treats
> the app as new, and you must remove and re-add it under Accessibility. A self-signed
> certificate named "SuperVoice Local Signing" (Keychain Access → Certificate Assistant → Create a
> Certificate, type Code Signing) avoids this.

## 4. Install

Either copy the bundle directly:

```bash
cp -R build/SuperVoiceAssistant.app /Applications/
open /Applications/SuperVoiceAssistant.app
```

or build a **DMG installer** and install from it (also the way to hand the app to another Mac):

```bash
bash scripts/build_dmg.sh             # builds the app bundle, then build/SuperVoiceAssistant-<version>.dmg
# or: bash scripts/build_dmg.sh --no-build   (packs the existing build/SuperVoiceAssistant.app)
```

Open the DMG, drag **SuperVoiceAssistant** onto **Applications**, eject the DMG, then start the
app from Applications or Spotlight. The script refuses to pack a bundle that contains a `.env`
file, so your API keys never end up in the DMG; each Mac uses its own `~/.env` (step 6).

> **On another Mac.** The DMG and the app are signed with your self-made "SuperVoice Local
> Signing" certificate, not an Apple Developer ID, and are not notarized, so Gatekeeper blocks
> the first start ("cannot verify the developer"). Start it once, then System Settings →
> Privacy & Security → **Open Anyway** for SuperVoiceAssistant. On that Mac, grant the
> permissions in step 5 again. If `/Applications/SuperVoiceAssistant.app` is a symlink to a
> project build, remove the symlink before dragging the app in.

What happens on first start:

- A **microphone icon** appears in the menu bar. There is no Dock icon and no window.
- The app registers itself to **start at login** (System Settings → General → Login Items lists
  it; remove it there if you do not want that).
- If Accessibility is not granted yet, an alert offers **Open Settings** (see step 5).

The app is not restarted after Quit or a crash; start it again from Applications or Spotlight.

## 5. Grant permissions

Open **System Settings → Privacy & Security** and allow:

| Permission | Needed for | How |
|---|---|---|
| **Accessibility** | all global shortcuts, pasting text at the cursor, Fn+Ctrl+Option(+Cmd) | Accessibility → **+** → choose `/Applications/SuperVoiceAssistant.app` → switch on |
| **Microphone** | every recording | macOS asks on the first recording; allow it |
| **Speech Recognition** | conversation mode, dictation mode, Apple Speech panel | macOS asks on first use; allow it |
| **Screen Recording** | Cmd+Option+C | Screen & System Audio Recording → add the app (or the terminal when run from source) |
| **Notifications** | status and error messages (e.g. the new speech language, a missing permission) | macOS asks at the first start; allow it. Later: System Settings → Notifications → SuperVoiceAssistant |

After changing Accessibility, **quit and start the app again**; the shortcuts are registered at
start.

Check it: right-click the icon → **Test Auto-Paste** with the cursor in a text field. A test text
must appear. If not, Accessibility is not in effect yet.

## 6. Optional: API keys

The app reads keys from the environment or from a `.env` file. It looks for `.env` in this order
and takes the first one it finds:

1. the folder of the executable and up to five folders above it
   (for the app in `/Applications` that is `…/Contents/MacOS`, `…/Contents`, the `.app`, and
   `/Applications`; for a build inside the project it reaches the project folder),
2. your home folder: **`~/.env`**,
3. the current working directory.

For the installed app, use **`~/.env`**:

```bash
cat >> ~/.env <<'EOF'
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=AIza...
EOF
chmod 600 ~/.env
```

Write only the keys you have. Then quit and start the app again. **Settings** (right-click →
Settings…) shows each key as *Configured* or *Not configured*.

> The app does **not** look inside the bundle (`Contents/Resources`), and the build script does
> not copy a `.env` there. A build in the project's `build/` folder finds the project `.env` by
> walking up; an app in `/Applications` uses `~/.env`.

## 7. First test of each feature

1. **Conversation mode (no key):** click into any text field (Notes, a chat), press
   **Fn+Ctrl+Option**, say a sentence. The words appear as you speak; after 7 seconds of silence
   Return is pressed. Press **Fn+Ctrl+Option** again to turn it off.
2. **Dictation mode (no key):** same, but press **Fn+Ctrl+Option+Cmd**. Pause as long as you
   like; Return is never pressed. Either chord turns it off.
3. **Apple Speech panel (no key):** right-click → **Apple Speech Panel** → **Start** (or ⌘M),
   speak, correct, **⌘Return** to paste into the app you came from.
4. **English / German (no key):** press **Fn+Ctrl+Option+L** (or right-click → **Speech
   Language**). A notification shows *English* or *Deutsch*; the menu item shows the current
   language. Start conversation mode and speak in that language. Switching while a mode runs
   takes effect at once; the panel uses the new language from its next Start.
5. **OpenAI (key):** cursor in a text field, **Cmd+Option+V**, speak, **double-tap Space**. The text is
   pasted. **Escape** leaves continue mode.
6. **Read aloud (Gemini key):** select a paragraph, **Cmd+Option+S**. Press again to stop.
7. **Screen recording (Gemini key + ffmpeg):** **Cmd+Option+C**, talk about what is on screen,
   **Cmd+Option+C** again. The transcript is pasted at the cursor.
8. **History:** **Cmd+Option+A**.

## 8. Optional settings

- **Audio Devices** tab: choose microphone and playback device.
- **Settings** tab: voice commands and trackpad gestures (see
  [docs/voice-commands-and-gestures.md](docs/voice-commands-and-gestures.md)).
- **Text replacements:** `config.json` in the folder the app is started from; works when run
  from the project folder (see README).
- **Gemini shortcut Cmd+Option+X:** off by default; uncomment the `geminiAudioRecording` line in
  `Sources/main.swift` and rebuild.

## 9. Running from source instead

```bash
swift build
swift run SuperVoiceAssistant
```

Grant Accessibility, Microphone, Speech Recognition and Screen Recording to your **terminal app**
(Terminal, iTerm2), since macOS attributes them to it. Put keys in the project's `.env` or
`~/.env`. `config.json` in the project folder is picked up because that is the working directory.

## 10. Troubleshooting

**Shortcuts do nothing / text is not pasted**
- Accessibility must be on for exactly this app. After a rebuild with ad-hoc signing: select the
  entry in Accessibility, remove it with **−**, add the app again, restart the app.
- Use **Test Auto-Paste** to check.

**Fn+Ctrl+Option (or Fn+Ctrl+Option+Cmd) does nothing**
- Needs Accessibility (it watches modifier keys globally). Press the keys together and
  release them without another key. Shift cancels the chord.
- Speech Recognition must be allowed; otherwise a notification says so.

**"OPENAI_API_KEY not found" / "GEMINI_API_KEY not found"**
- The key is not in `~/.env` or is misspelled. Settings shows the status. Restart after editing.

**Read aloud does nothing**
- Needs `GEMINI_API_KEY` at start; the speech components are only set up when the key is found
  at launch. Add the key, restart.

**Screen recording fails**
- `which ffmpeg` must print a path. Screen Recording permission must be on. The recording is
  kept on the Desktop (`screen-recording-<date>.mp4`) when transcription fails.

**"Cannot start … another recording is active"**
- Only one recording at a time. Stop the running one (the menu-bar status shows which).

**German is recognized poorly, or sessions break off after about a minute**
- The German on-device model is not installed, so macOS uses Apple's servers. Add German in
  System Settings → Keyboard → Dictation → Languages; once downloaded, recognition runs on the Mac.

**No notifications appear**
- System Settings → Notifications → SuperVoiceAssistant → Allow Notifications.

**Conversation or dictation mode turned itself off**
- The microphone input disappeared (device change, sleep/wake). Start it again.

**"App is damaged" or it will not open**
```bash
xattr -cr /Applications/SuperVoiceAssistant.app
codesign --force --deep --sign - /Applications/SuperVoiceAssistant.app
```

**See what the app logs**
```bash
/Applications/SuperVoiceAssistant.app/Contents/MacOS/SuperVoiceAssistant
```
Started like this, its log lines (keys found, shortcuts registered, permission state) print to
the terminal.

## 11. Uninstall

```bash
osascript -e 'quit app "SuperVoiceAssistant"'
rm -rf /Applications/SuperVoiceAssistant.app
rm -rf ~/Documents/SuperVoiceAssistant     # history and statistics
```

Remove it from System Settings → General → Login Items and from the Privacy & Security lists, and
delete the keys from `~/.env` if you no longer need them.
