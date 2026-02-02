import Foundation

/// Recording states for the state machine
public enum RecordingState: Equatable, CustomStringConvertible, Sendable {
    case idle
    case starting
    case recording
    case processing
    case continueMode

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .processing: return "processing"
        case .continueMode: return "continueMode"
        }
    }

    /// Valid transitions from each state
    var validTransitions: Set<RecordingState> {
        switch self {
        case .idle:
            return [.starting]
        case .starting:
            return [.recording, .idle] // Can fail back to idle
        case .recording:
            return [.processing, .idle] // Processing on stop, idle on cancel
        case .processing:
            return [.continueMode, .idle] // Continue mode after transcription, or idle
        case .continueMode:
            return [.starting, .idle] // Start new recording or exit
        }
    }

    func canTransition(to newState: RecordingState) -> Bool {
        return validTransitions.contains(newState)
    }
}

/// Recording source identifier
public enum RecordingSource: Equatable, Hashable, Sendable {
    case openai
    case gemini
    case screen
}

extension RecordingSource: CustomStringConvertible {
    public var description: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .screen: return "Screen"
        }
    }
}

/// Thread-safe state manager for recording operations
/// Use only from main thread for UI updates
public final class RecordingStateManager {
    public static let shared = RecordingStateManager()

    private let lock = NSLock()
    private var _currentState: RecordingState = .idle
    private var _activeSource: RecordingSource?

    /// Observers for state changes (called on main thread)
    private var stateChangeHandlers: [(RecordingState, RecordingSource?) -> Void] = []

    public var currentState: RecordingState {
        lock.lock()
        defer { lock.unlock() }
        return _currentState
    }

    public var activeSource: RecordingSource? {
        lock.lock()
        defer { lock.unlock() }
        return _activeSource
    }

    private init() {}

    /// Attempt to transition to a new state
    /// - Parameters:
    ///   - newState: The target state
    ///   - source: The recording source (required for non-idle states)
    /// - Returns: True if transition was successful
    @discardableResult
    public func transition(to newState: RecordingState, source: RecordingSource? = nil) -> Bool {
        lock.lock()

        let oldState = _currentState

        // If transitioning to idle, always allow (reset)
        if newState == .idle {
            _currentState = .idle
            _activeSource = nil
            lock.unlock()
            notifyStateChange(from: oldState)
            print("🔄 State: \(oldState) → idle")
            return true
        }

        // Validate transition
        guard oldState.canTransition(to: newState) else {
            lock.unlock()
            print("❌ Invalid state transition: \(oldState) → \(newState)")
            return false
        }

        // For non-idle states, require source when starting
        if newState == .starting {
            guard let source = source else {
                lock.unlock()
                print("❌ Source required when starting recording")
                return false
            }

            // Check if another source is active
            if _activeSource != nil && _activeSource != source {
                lock.unlock()
                print("❌ Cannot start \(source) - \(_activeSource!) is active")
                return false
            }

            _activeSource = source
        }

        _currentState = newState
        lock.unlock()
        notifyStateChange(from: oldState)
        print("🔄 State: \(oldState) → \(newState) (\(source?.description ?? activeSource?.description ?? "none"))")
        return true
    }

    /// Check if a specific source can start recording
    public func canStart(source: RecordingSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard _currentState == .idle || _currentState == .continueMode else {
            return false
        }

        // If in continue mode, only the same source can continue
        if _currentState == .continueMode {
            return _activeSource == source
        }

        return true
    }

    /// Check if currently recording (for UI status)
    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _currentState == .recording
    }

    /// Check if any operation is in progress
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _currentState != .idle
    }

    /// Check if in continue mode
    public var inContinueMode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _currentState == .continueMode
    }

    /// Force reset to idle state (for error recovery)
    public func forceReset() {
        lock.lock()
        let oldState = _currentState
        _currentState = .idle
        _activeSource = nil
        lock.unlock()
        print("⚠️ Force resetting state from \(oldState)")
        notifyStateChange(from: oldState)
    }

    /// Register a handler for state changes
    public func onStateChange(_ handler: @escaping (RecordingState, RecordingSource?) -> Void) {
        lock.lock()
        stateChangeHandlers.append(handler)
        lock.unlock()
    }

    private func notifyStateChange(from oldState: RecordingState) {
        lock.lock()
        let handlers = stateChangeHandlers
        let state = _currentState
        let source = _activeSource
        lock.unlock()

        DispatchQueue.main.async {
            for handler in handlers {
                handler(state, source)
            }
        }
    }
}
