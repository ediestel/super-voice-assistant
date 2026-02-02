import Foundation
import AVFoundation
import CoreAudio

/// Audio session types for coordination
public enum AudioSessionType: Equatable, CustomStringConvertible {
    case recording(source: String)
    case playback
    case none

    public var description: String {
        switch self {
        case .recording(let source): return "Recording(\(source))"
        case .playback: return "Playback"
        case .none: return "None"
        }
    }
}

/// Centralized audio session manager to coordinate recording and playback
/// Prevents resource conflicts between multiple AVAudioEngines
@MainActor
public final class AudioSessionManager: ObservableObject {
    public static let shared = AudioSessionManager()

    @Published private(set) var activeSession: AudioSessionType = .none
    @Published private(set) var isInterrupted = false

    private var activeEngine: AVAudioEngine?
    private let sessionLock = NSLock()

    private init() {
        setupNotifications()
    }

    /// Request to start an audio session
    /// - Parameters:
    ///   - type: Type of audio session
    ///   - engine: The AVAudioEngine to track
    /// - Returns: true if session was granted
    public func requestSession(_ type: AudioSessionType, engine: AVAudioEngine) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        // Check for conflicts
        switch (activeSession, type) {
        case (.none, _):
            // No active session, allow
            break
        case (_, .none):
            // Releasing session, allow
            break
        case (.recording, .recording):
            // Cannot have two recordings at once
            print("❌ AudioSession: Recording already in progress")
            return false
        case (.playback, .recording):
            // Stop playback to allow recording
            print("⚠️ AudioSession: Stopping playback for recording")
            stopActiveEngine()
        case (.recording, .playback):
            // Cannot interrupt recording with playback
            print("❌ AudioSession: Cannot start playback during recording")
            return false
        case (.playback, .playback):
            // Replace current playback
            print("⚠️ AudioSession: Replacing active playback")
            stopActiveEngine()
        }

        activeSession = type
        activeEngine = engine
        print("✅ AudioSession: Started \(type)")
        return true
    }

    /// Release the current audio session
    public func releaseSession() {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if activeSession != .none {
            print("✅ AudioSession: Released \(activeSession)")
            stopActiveEngine()
            activeSession = .none
            activeEngine = nil
        }
    }

    /// Check if a session type can be started
    public func canStart(_ type: AudioSessionType) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        switch (activeSession, type) {
        case (.none, _):
            return true
        case (.playback, .recording):
            return true // Will stop playback
        case (.playback, .playback):
            return true // Will replace
        default:
            return false
        }
    }

    /// Get whether recording is currently active
    public var isRecording: Bool {
        if case .recording = activeSession {
            return true
        }
        return false
    }

    /// Get whether playback is currently active
    public var isPlaying: Bool {
        return activeSession == .playback
    }

    private func stopActiveEngine() {
        if let engine = activeEngine {
            if engine.isRunning {
                engine.stop()
            }
            activeEngine = nil
        }
    }

    // MARK: - Audio Device Change Handling (macOS)

    private func setupNotifications() {
        // On macOS, we listen for default device changes via CoreAudio
        // This is handled by AudioDeviceManager, so we just log here
        print("✅ AudioSessionManager initialized")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Audio Device Configuration Helper

extension AudioSessionManager {
    /// Configure an audio engine's input node with the selected input device
    public func configureInputDevice(for engine: AVAudioEngine, deviceManager: AudioDeviceManager) {
        guard !deviceManager.useSystemDefaultInput,
              let selectedUID = deviceManager.selectedInputDeviceUID,
              let deviceID = deviceManager.getAudioDeviceID(for: selectedUID) else {
            print("✅ Using system default input device")
            return
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceIDValue = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceIDValue
        )

        if status == noErr {
            let deviceName = deviceManager.availableInputDevices.first { $0.uid == selectedUID }?.name ?? selectedUID
            print("✅ Set input to \(deviceName)")
        } else {
            print("⚠️ Failed to set input device (error: \(status))")
        }
    }

    /// Configure an audio engine's output node with the selected output device
    public func configureOutputDevice(for engine: AVAudioEngine, deviceManager: AudioDeviceManager) {
        guard !deviceManager.useSystemDefaultOutput,
              let device = deviceManager.getCurrentOutputDevice(),
              let deviceID = deviceManager.getAudioDeviceID(for: device.uid) else {
            return
        }

        do {
            try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            print("✅ Set output to \(device.name)")
        } catch {
            print("⚠️ Failed to set output device: \(error)")
        }
    }
}
