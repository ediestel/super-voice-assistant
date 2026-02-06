# Super Voice Assistant - Installation Guide

## ✅ App Bundle Created Successfully

Your `SuperVoiceAssistant.app` bundle is ready at:
```
/Users/eckhartdiestel/Desktop/Coding_Projects/super-voice-assistant/build/SuperVoiceAssistant.app
```

**Bundle Size**: 4.5 MB
**Architecture**: ARM64 (Apple Silicon)
**Build Type**: Debug (for development and testing)

---

## 📦 Installation Steps

### 1. Copy to Applications Folder

```bash
cp -r "/Users/eckhartdiestel/Desktop/Coding_Projects/super-voice-assistant/build/SuperVoiceAssistant.app" /Applications/
```

Or drag and drop the app from Finder to your Applications folder.

### 2. Configure API Keys

The app needs your API keys to function. These were already copied to the bundle if you had a `.env` file.

**Option A: Check if .env exists in the bundle**
```bash
ls -la /Applications/SuperVoiceAssistant.app/Contents/Resources/.env
```

**Option B: Create/Edit .env file manually**
```bash
# Right-click app in Applications → Show Package Contents
# Navigate to Contents/Resources/
# Create .env file with:
GEMINI_API_KEY=your_gemini_api_key_here
OPENAI_API_KEY=your_openai_api_key_here
```

Or from terminal:
```bash
cat > /Applications/SuperVoiceAssistant.app/Contents/Resources/.env << 'EOF'
GEMINI_API_KEY=your_gemini_api_key_here
OPENAI_API_KEY=your_openai_api_key_here
EOF
```

### 3. Grant Required Permissions

The app needs these permissions to function:

**Microphone Access** (Required)
- System Settings → Privacy & Security → Microphone
- Enable for Super Voice Assistant

**Accessibility Access** (Required for auto-paste and gestures)
- System Settings → Privacy & Security → Accessibility
- Click the lock to make changes
- Click + button
- Navigate to Applications and add Super Voice Assistant
- Enable the checkbox

### 4. Launch the App

**From Applications:**
```bash
open /Applications/SuperVoiceAssistant.app
```

**Or double-click** SuperVoiceAssistant.app in Finder.

**First Launch Note**: macOS may show a security warning for apps not from the App Store.
- Right-click the app → Open
- Click "Open" in the dialog
- This only needs to be done once

---

## 🎯 Quick Start

Once launched, the app runs in the menu bar (top-right corner).

### Basic Usage

**Start OpenAI Recording:**
```
Press: Cmd+Opt+Z
Speak your text
Press: Space (double-tap) to stop
→ Text auto-pastes at cursor
```

**Start Gemini Recording:**
```
Press: Cmd+Opt+X
Speak your text
Automatic stop when you finish speaking
→ Text auto-pastes at cursor
```

**Read Selected Text Aloud (Gemini TTS):**
```
Select any text
Press: Cmd+Opt+S
→ Text is read aloud with natural voice
```

**View Transcription History:**
```
Press: Cmd+Opt+A
→ Shows all your recent transcriptions
```

### New Features (Just Added!)

**Voice Commands** (Enable in Settings):
- Say "stop recording" to stop
- Say "cancel recording" to discard
- Say "continue recording" to restart

**Trackpad Gestures** (Enable in Settings):
- Three-finger swipe down: Start recording
- Three-finger swipe up: Stop recording
- Force touch: Toggle recording

---

## ⚙️ Settings

Access settings from the menu bar icon → Settings

**Configure:**
- API key status (read from .env)
- Keyboard shortcuts reference
- Voice commands (enable/disable)
- Command removal from transcription
- Trackpad gestures (enable/disable)

---

## 🔧 Troubleshooting

### App Won't Launch

**Check logs:**
```bash
open /Applications/SuperVoiceAssistant.app
# Then check Console.app for crash logs
```

**Verify executable:**
```bash
file /Applications/SuperVoiceAssistant.app/Contents/MacOS/SuperVoiceAssistant
# Should show: Mach-O 64-bit executable arm64
```

### "App is Damaged" Error

```bash
# Remove quarantine attribute
xattr -cr /Applications/SuperVoiceAssistant.app

# Re-sign the app
codesign --force --deep --sign - /Applications/SuperVoiceAssistant.app
```

### API Keys Not Working

**Verify .env file:**
```bash
cat /Applications/SuperVoiceAssistant.app/Contents/Resources/.env
```

**Check format:**
- No spaces around `=`
- No quotes around keys (unless part of the key)
- One key per line

### Permissions Not Working

**Reset permissions:**
```bash
tccutil reset Microphone
tccutil reset Accessibility
```

Then re-grant permissions in System Settings.

### Recording Not Working

1. **Check microphone permission** (System Settings → Privacy → Microphone)
2. **Check selected audio input** (Settings → Audio Input Device)
3. **Verify API keys** are present in .env file
4. **Check Console.app** for error messages

---

## 🚀 Building Release Version

For production use, build a release version:

```bash
cd /Users/eckhartdiestel/Desktop/Coding_Projects/super-voice-assistant
./scripts/build_app_bundle.sh release
```

This creates an optimized build but requires fixing the test-text-inserter compilation issue first.

**Alternative (single architecture):**
```bash
swift build -c release
./scripts/build_app_bundle.sh release
```

---

## 📁 App Bundle Structure

```
SuperVoiceAssistant.app/
├── Contents/
│   ├── Info.plist              # App metadata
│   ├── MacOS/
│   │   └── SuperVoiceAssistant # Executable (2.6 MB)
│   ├── Resources/
│   │   ├── AppIcon.icns        # App icon (1.9 MB)
│   │   └── .env                # API keys (you create this)
│   └── _CodeSignature/         # Ad-hoc signature
```

---

## 🔐 Security Notes

- **Ad-hoc Signed**: The app is signed with an ad-hoc signature (local use only)
- **Not Notarized**: Cannot be distributed publicly without Apple Developer account
- **Privacy**: All voice processing happens via API calls to OpenAI/Gemini
- **Local Data**: Transcription history stored locally only

---

## 📊 Features Summary

### Keyboard Shortcuts
- **Cmd+Opt+Z**: OpenAI Realtime recording
- **Cmd+Opt+X**: Gemini audio recording
- **Cmd+Opt+S**: Read selected text aloud (Gemini TTS)
- **Cmd+Opt+C**: Screen recording with video transcription
- **Cmd+Opt+A**: Show transcription history
- **Space** (during recording): Stop recording
- **Escape** (during recording): Cancel recording

### Voice Commands (Optional)
- "stop recording" - Stop and transcribe
- "cancel recording" - Discard recording
- "continue recording" - Start new recording

### Trackpad Gestures (Optional)
- Three-finger swipe down: Start recording
- Three-finger swipe up: Stop recording
- Force touch: Toggle recording

---

## 🆘 Support

**Documentation:**
- `README.md` - Project overview
- `docs/voice-commands-and-gestures.md` - Voice/gesture features
- `CLAUDE.md` - Development notes

**Console Logs:**
```bash
# Watch app logs in real-time
log stream --predicate 'subsystem == "com.supervoice.SuperVoiceAssistant"' --level debug
```

**GitHub Issues:**
- Report bugs or request features at the project repository

---

## ✅ You're All Set!

Your Super Voice Assistant is ready to use. Enjoy hands-free transcription! 🎤
