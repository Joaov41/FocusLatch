@preconcurrency import AppKit
@preconcurrency import Foundation
import MultitouchBridge

final class GestureMonitor {
    private let tapDebounceInterval: TimeInterval = 0.35
    private let onPinToggleGesture: () -> Void
    private let onFocusToggleGesture: () -> Void
    private var isRunning = false
    private var lastTapTimestamp: TimeInterval = 0

    init(onPinToggleGesture: @escaping () -> Void, onFocusToggleGesture: @escaping () -> Void) {
        self.onPinToggleGesture = onPinToggleGesture
        self.onFocusToggleGesture = onFocusToggleGesture
    }

    func start() -> Bool {
        guard !isRunning else {
            return true
        }

        let didStart = MTBridgeStart(Unmanaged.passUnretained(self).toOpaque(), focusLatchGestureCallback)
        isRunning = didStart
        return didStart
    }

    func stop() {
        guard isRunning else {
            return
        }

        MTBridgeStop()
        isRunning = false
    }

    fileprivate func handleGesture(_ gestureType: Int32) {
        switch gestureType {
        case Int32(MTGestureTypeThreeFingerTap):
            let now = ProcessInfo.processInfo.systemUptime
            guard (now - lastTapTimestamp) >= tapDebounceInterval else {
                return
            }

            lastTapTimestamp = now

            if NSEvent.modifierFlags.contains(.shift) {
                onFocusToggleGesture()
            } else {
                onPinToggleGesture()
            }
        default:
            break
        }
    }

    deinit {
        stop()
    }
}

@_cdecl("focusLatchGestureCallback")
private func focusLatchGestureCallback(_ context: UnsafeMutableRawPointer?, _ gestureType: Int32) {
    guard let context else {
        return
    }

    let monitor = Unmanaged<GestureMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleGesture(gestureType)
}
