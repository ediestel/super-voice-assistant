import Foundation
import AppKit

/// Double-tap detector with configurable time window
public final class DoubleTapDetector {
    private var lastTapTime: Date?
    public let tapWindow: TimeInterval

    /// Initialize with configurable tap window
    /// - Parameter tapWindow: Time window in seconds for double-tap detection
    public init(tapWindow: TimeInterval = 0.8) {
        self.tapWindow = tapWindow
    }

    /// Record a tap and return whether it's a double-tap
    /// - Returns: true if this is the second tap within the window
    public func recordTap() -> Bool {
        let now = Date()
        defer { lastTapTime = now }

        if let last = lastTapTime, now.timeIntervalSince(last) < tapWindow {
            lastTapTime = nil // Reset after successful double-tap
            return true
        }
        return false
    }

    /// Reset the detector state
    public func reset() {
        lastTapTime = nil
    }
}

/// Key codes for commonly used keys
public enum KeyCode: UInt16 {
    case space = 49
    case escape = 53
    case returnKey = 36
}

/// Protocol for keyboard event handling
public protocol KeyboardEventDelegate: AnyObject {
    func handleSpaceDoubleTap()
    func handleEscapeKey()
    func handleSpaceContinue()
    func handleEscapeContinue()
}

/// Centralized keyboard event handler that consolidates all NSEvent monitors
public final class KeyboardEventHandler {
    public static let shared = KeyboardEventHandler()

    public weak var delegate: KeyboardEventDelegate?

    private var globalMonitor: Any?
    private let doubleTapDetector: DoubleTapDetector
    private var isEnabled = false
    private var _mode: Mode = .inactive
    private let lock = NSLock()

    public enum Mode {
        case inactive
        case recording    // Listening for double-tap space to stop, escape to cancel
        case continueMode // Listening for space to continue, escape to exit
    }

    public var mode: Mode {
        lock.lock()
        defer { lock.unlock() }
        return _mode
    }

    private init() {
        // Load double-tap window from UserDefaults (in ms) or use default 800ms
        let storedMs = UserDefaults.standard.double(forKey: "spaceTapInterval")
        let tapWindow = storedMs > 0 ? storedMs / 1000.0 : 0.8
        self.doubleTapDetector = DoubleTapDetector(tapWindow: tapWindow)
    }

    /// Set the current mode for keyboard handling
    public func setMode(_ newMode: Mode) {
        lock.lock()
        let wasEnabled = isEnabled
        _mode = newMode
        lock.unlock()

        switch newMode {
        case .inactive:
            if wasEnabled {
                stopMonitoring()
            }
        case .recording, .continueMode:
            if !wasEnabled {
                startMonitoring()
            }
        }

        // Reset double-tap detection when switching modes
        doubleTapDetector.reset()
        print("⌨️ Keyboard mode: \(newMode)")
    }

    /// Start the global keyboard monitor
    private func startMonitoring() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        lock.lock()
        isEnabled = true
        lock.unlock()

        print("⌨️ Keyboard monitor started")
    }

    /// Stop the global keyboard monitor
    private func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        lock.lock()
        isEnabled = false
        lock.unlock()

        doubleTapDetector.reset()
        print("⌨️ Keyboard monitor stopped")
    }

    /// Handle incoming key events based on current mode
    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode

        lock.lock()
        let currentMode = _mode
        lock.unlock()

        switch currentMode {
        case .inactive:
            // Should not receive events in inactive mode
            return

        case .recording:
            if keyCode == KeyCode.space.rawValue {
                // Double-tap detection for stopping recording
                if doubleTapDetector.recordTap() {
                    print("⏹ Double-tap Space detected - stopping recording")
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.handleSpaceDoubleTap()
                    }
                } else {
                    print("⏸ First Space tap (tap again within \(Int(doubleTapDetector.tapWindow * 1000))ms to stop)")
                }
            } else if keyCode == KeyCode.escape.rawValue {
                print("🛑 Escape pressed - cancelling recording")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.handleEscapeKey()
                }
            }

        case .continueMode:
            if keyCode == KeyCode.space.rawValue {
                print("⏎ Space pressed - continuing recording")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.handleSpaceContinue()
                }
            } else if keyCode == KeyCode.escape.rawValue {
                print("❌ Escape pressed - exiting continue mode")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.handleEscapeContinue()
                }
            }
        }
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
