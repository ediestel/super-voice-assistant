import Foundation
import AppKit
import CoreGraphics

/// Protocol for gesture event handling
public protocol GestureEventDelegate: AnyObject {
    func handleThreeFingerSwipeDown()  // Start recording
    func handleThreeFingerSwipeUp()    // Stop recording
    func handleForceTouch()             // Toggle recording
    func handleFourFingerTap()         // Cancel recording
}

/// System-wide trackpad gesture handler for recording control
/// Uses NSEvent local monitoring - gestures only work when app is active
public final class GestureEventHandler {
    public static let shared = GestureEventHandler()

    public weak var delegate: GestureEventDelegate?

    private var gestureMonitor: Any?
    private var pressureMonitor: Any?
    private var isEnabled = false

    // Gesture detection state
    private var forceLevel: CGFloat = 0.0
    private var lastForceTouchTime: Date?
    private let forceTouchCooldown: TimeInterval = 1.0

    // Configuration
    public var isGestureEnabled: Bool {
        get { isEnabled }
        set {
            if newValue && !isEnabled {
                startMonitoring()
            } else if !newValue && isEnabled {
                stopMonitoring()
            }
        }
    }

    private init() {
        // Check if we have accessibility permissions
        checkAccessibilityPermission()
    }

    private func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessEnabled {
            print("⚠️ Accessibility permission recommended for gesture support")
            print("   Add this app to System Settings > Privacy & Security > Accessibility")
        }
    }

    /// Start monitoring trackpad gestures
    public func startMonitoring() {
        guard gestureMonitor == nil else {
            print("⌨️ Gesture monitor already running")
            return
        }

        // Monitor swipe gestures
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe]) { [weak self] event in
            self?.handleSwipeEvent(event)
            return event
        }

        // Monitor pressure/force touch
        pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure, .gesture]) { [weak self] event in
            self?.handlePressureEvent(event)
            return event
        }

        isEnabled = true
        print("👆 Gesture monitor started (local monitoring)")
        print("   Three-finger swipe down: Start recording")
        print("   Three-finger swipe up: Stop recording")
        print("   Force touch: Toggle recording")
        print("   Note: Gestures work when app window is active")
    }

    /// Stop monitoring trackpad gestures
    public func stopMonitoring() {
        if let monitor = gestureMonitor {
            NSEvent.removeMonitor(monitor)
            gestureMonitor = nil
        }

        if let monitor = pressureMonitor {
            NSEvent.removeMonitor(monitor)
            pressureMonitor = nil
        }

        isEnabled = false
        print("👆 Gesture monitor stopped")
    }

    /// Handle swipe events
    private func handleSwipeEvent(_ event: NSEvent) {
        let deltaX = event.deltaX
        let deltaY = event.deltaY

        // Detect vertical swipes (deltaY has stronger signal)
        if abs(deltaY) > abs(deltaX) && abs(deltaY) > 0.1 {
            if deltaY > 0 {
                // Swipe up
                DispatchQueue.main.async { [weak self] in
                    print("👆 Three-finger swipe up detected")
                    self?.delegate?.handleThreeFingerSwipeUp()
                }
            } else if deltaY < 0 {
                // Swipe down
                DispatchQueue.main.async { [weak self] in
                    print("👆 Three-finger swipe down detected")
                    self?.delegate?.handleThreeFingerSwipeDown()
                }
            }
        }
    }

    /// Handle pressure/force touch events
    private func handlePressureEvent(_ event: NSEvent) {
        // Check for force click (stage 2 pressure)
        if event.stage == 2 {
            // Check cooldown to prevent duplicate triggers
            if let lastTime = lastForceTouchTime,
               Date().timeIntervalSince(lastTime) < forceTouchCooldown {
                return
            }

            lastForceTouchTime = Date()

            DispatchQueue.main.async { [weak self] in
                print("👆 Force touch detected")
                self?.delegate?.handleForceTouch()
            }
        }
    }

    deinit {
        stopMonitoring()
    }
}

// MARK: - Global Monitoring Alternative (requires Accessibility)

extension GestureEventHandler {
    /// Start global gesture monitoring (works system-wide)
    /// Requires Accessibility permission
    public func startGlobalMonitoring() {
        // Global monitoring for gestures is limited in macOS
        // Most gesture events are not available via CGEvent
        // For now, we use local monitoring which is more reliable

        print("⚠️ Global gesture monitoring not fully supported")
        print("   Using local monitoring instead (gestures work when app is active)")
        startMonitoring()
    }
}

// MARK: - Alternative: Magic Mouse Support

extension GestureEventHandler {
    /// Enable Magic Mouse gesture support
    /// Uses scroll wheel events to detect two-finger swipes
    public func enableMagicMouseGestures() {
        // Monitor scroll events that could be Magic Mouse swipes
        let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            // Magic Mouse swipes generate high delta values
            if event.momentumPhase == .began {
                let deltaY = event.scrollingDeltaY

                if abs(deltaY) > 20 {
                    if deltaY > 0 {
                        self?.delegate?.handleThreeFingerSwipeUp()
                    } else {
                        self?.delegate?.handleThreeFingerSwipeDown()
                    }
                }
            }
            return event
        }

        print("🖱 Magic Mouse gesture support enabled")
    }
}
