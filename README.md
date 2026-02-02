# Super Voice Assistant

macOS voice assistant with global hotkeys - transcribe speech to text with cloud-based OpenAI or Gemini APIs, capture and transcribe screen recordings with visual context for better accuracy on code/technical terms, and read selected text out loud with live Gemini models. Compared to other options, it's faster and more accurate with simple UI/UX.

## Demo

**Instant text-to-speech:**

https://github.com/user-attachments/assets/c961f0c6-f3b3-49d9-9b42-7a7d93ee6bc8

**Visual disambiguation for names:**

https://github.com/user-attachments/assets/0b7f481f-4fec-4811-87ef-13737e0efac4

## Features

**Voice-to-Text Transcription**
- Press Command+Option+Z for cloud transcription with OpenAI Realtime API (primary)
- Press Command+Option+X for cloud transcription with Gemini API
- Automatic text pasting at cursor position
- Transcription history with Command+Option+A

**Streaming Text-to-Speech**
- Press Command+Option+S to read selected text aloud using Gemini Live API
- Press Command+Option+S again while reading to cancel the operation
- Sequential streaming for smooth, natural speech with minimal latency
- Smart sentence splitting for optimal speech flow

**Screen Recording & Video Transcription**
- Press Command+Option+C to start/stop screen recording
- Automatic video transcription using Gemini 2.5 Flash API with visual context
- Better accuracy for programming terms, code, technical jargon, and ambiguous words
- Transcribed text automatically pastes at cursor position

## Requirements

- macOS 14.0 or later
- Xcode 15+ or Xcode Command Line Tools (for Swift 5.9+)
- OpenAI API key (for primary voice transcription)
- Gemini API key (for text-to-speech, video transcription, and Gemini audio)
- ffmpeg (for screen recording functionality)

## System Permissions Setup

This app requires specific system permissions to function properly:

### 1. Microphone Access
The app will automatically request microphone permission on first launch. If denied, grant it manually:
- Go to **System Settings > Privacy & Security > Microphone**
- Enable access for **Super Voice Assistant**

### 2. Accessibility Access (Required for Global Hotkeys & Auto-Paste)
You must manually grant accessibility permissions for the app to:
- Monitor global keyboard shortcuts (Command+Option+Z/X/Y/S/A/C, Space, Escape)
- Automatically paste transcribed text at cursor position

**To enable:**
1. Go to **System Settings > Privacy & Security > Accessibility**
2. Click the lock icon to make changes (enter your password)
3. Click the **+** button to add an application
4. Navigate to the app location:
   - If running via `swift run`: Add **Terminal** or your terminal app (iTerm2, etc.)
   - If running the built binary directly: Add the **SuperVoiceAssistant** executable
5. Ensure the checkbox next to the app is checked

**Important:** Without accessibility access, the app cannot detect global hotkeys (Command+Option+Z/X/Y/A/S/C, Space, Escape) or paste text automatically.

### 3. Screen Recording Access (Required for Video Transcription)
The app requires screen recording permission to capture screen content:
- Go to **System Settings > Privacy & Security > Screen Recording**
- Enable access for **Terminal** (if running via `swift run`) or **SuperVoiceAssistant**

## Installation & Running

```bash
# Clone the repository
git clone https://github.com/ediestel/super-voice-assistant.git
cd super-voice-assistant

# Install ffmpeg (required for screen recording)
brew install ffmpeg

# Set up environment - create .env file with your API keys
echo "OPENAI_API_KEY=your-openai-key" >> .env
echo "GEMINI_API_KEY=your-gemini-key" >> .env

# Build the app
swift build

# Run the app
swift run SuperVoiceAssistant
```

The app will appear in your menu bar as a waveform icon.

### Quick Launch Alias (Recommended)

For easy launching from anywhere, add a shell alias:

```bash
# Add alias to your shell config
echo 'alias ccc="/path/to/super-voice-assistant/.build/arm64-apple-macosx/debug/SuperVoiceAssistant"' >> ~/.zshrc
source ~/.zshrc

# Now just run:
ccc
```

Replace `/path/to/super-voice-assistant` with your actual project path.

**Note:** The app automatically finds your `.env` file by searching up from the executable location to the project root, so you can run `ccc` from any directory.

## Configuration

### Text Replacements

You can configure automatic text replacements for transcriptions by editing `config.json` in the project root:

```json
{
  "textReplacements": {
    "Cloud Code": "Claude Code",
    "cloud code": "claude code",
    "cloud.md": "CLAUDE.md"
  }
}
```

This is useful for correcting common speech-to-text misrecognitions, especially for proper nouns, brand names, or technical terms. Replacements are case-sensitive and applied to all transcriptions.

## Usage

### Voice-to-Text Transcription

**Cloud (OpenAI Realtime - Primary):**
1. Ensure OPENAI_API_KEY is set in your .env file
2. Press **Command+Option+Z** to start recording (menu bar icon shows recording indicator)
3. Press **Space** to stop recording and transcribe, or **Escape** to cancel
4. After transcription, press **Space** again to start a new recording (continue mode)
5. Press **Escape** to exit continue mode
6. The transcribed text automatically pastes at your cursor position

**Cloud (Gemini API):**
1. Ensure GEMINI_API_KEY is set in your .env file
2. Press **Command+Option+X** to start recording (menu bar icon shows recording indicator)
3. Press **Command+Option+X** again to stop recording and transcribe
4. The transcribed text automatically pastes at your cursor position
5. Press **Escape** during recording to cancel without transcribing

**When to use which:**
- **OpenAI Realtime (Cmd+Option+Z)**: Cloud-based, real-time streaming, best accuracy, space bar controls
- **Gemini (Cmd+Option+X)**: Cloud-based, good accuracy for complex audio

### Text-to-Speech
1. Select any text in any application
2. Press **Command+Option+S** to read the selected text aloud
3. Press **Command+Option+S** again while reading to cancel the operation
4. The app uses Gemini Live API for natural, streaming speech synthesis
5. Configure audio devices via Settings for optimal playback

### Screen Recording & Video Transcription
1. Press **Command+Option+C** to start screen recording
2. The menu bar shows "🎥 REC" while recording
3. Press **Command+Option+C** again to stop recording
4. The app automatically transcribes the video using Gemini 2.5 Flash
5. Visual context improves accuracy for code, technical terms, and homophones
6. Transcribed text pastes at your cursor position
7. Video file is automatically deleted after successful transcription

**Note:** Audio recording and screen recording are mutually exclusive - you cannot run both simultaneously.

**When to use video vs audio:**
- **Video**: Programming, code review, technical documentation, names, acronyms, specialized terminology
- **Audio**: General speech, quick notes, casual transcription

### Keyboard Shortcuts

- **Command+Option+Z**: Start OpenAI Realtime recording (cloud, primary)
- **Command+Option+X**: Start/stop Gemini audio recording (cloud)
- **Command+Option+S**: Read selected text aloud / Cancel TTS playback
- **Command+Option+C**: Start/stop screen recording and transcribe
- **Command+Option+A**: Show transcription history window

**During OpenAI Recording (Cmd+Option+Z):**
- **Space**: Stop recording and transcribe
- **Escape**: Cancel recording (discard)

**After OpenAI Transcription (Continue Mode):**
- **Space**: Start new recording
- **Escape**: Exit continue mode

## Available Commands

```bash
# Run the main app
swift run SuperVoiceAssistant

# Or use the alias (if configured)
ccc

# Test streaming TTS functionality
swift run TestStreamingTTS

# Test audio collection for TTS
swift run TestAudioCollector

# Test sentence splitting for TTS
swift run TestSentenceSplitter

# Test screen recording (3-second capture)
swift run RecordScreen

# Test video transcription with Gemini API
swift run TranscribeVideo <path-to-video-file>
# Example: swift run TranscribeVideo ~/Desktop/recording.mp4
```

## Project Structure

- `Sources/` - Main app code
  - `main.swift` - App entry point and delegate
  - `ScreenRecorder.swift` - Screen recording with ffmpeg
  - `OpenAIAudioRecordingManager.swift` - OpenAI recording manager
  - `GeminiAudioRecordingManager.swift` - Gemini recording manager
- `SharedSources/` - Shared components
  - `EnvironmentLoader.swift` - .env file loading with swift-dotenv
  - `OpenAIRealtimeTranscriber.swift` - OpenAI Realtime API transcription
  - `GeminiAudioTranscriber.swift` - Gemini API audio transcription
  - `GeminiStreamingPlayer.swift` - Streaming TTS playback engine
  - `GeminiAudioCollector.swift` - Audio collection and WebSocket handling
  - `SmartSentenceSplitter.swift` - Text processing for optimal speech
  - `VideoTranscriber.swift` - Gemini API video transcription
- `tests/` - Test utilities:
  - `test-streaming-tts/` - TTS functionality test
  - `test-audio-collector/` - Audio collection test
  - `test-sentence-splitter/` - Sentence splitting test
  - `test-openai-transcription/` - OpenAI transcription test
- `tools/` - Utilities:
  - `record-screen/` - Screen recording test tool
  - `transcribe-video/` - Video transcription test tool
- `scripts/` - Build and icon generation scripts
- `logos/` - Logo and branding assets

## License

See [LICENSE](LICENSE) for details.
