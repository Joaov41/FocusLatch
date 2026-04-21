@preconcurrency import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let focusLockManager = FocusLockManager(ignoredBundleIdentifier: Bundle.main.bundleIdentifier)
    private let windowPinManager = WindowPinManager(ignoredBundleIdentifier: Bundle.main.bundleIdentifier)
    private let launchAtLoginManager = LaunchAtLoginManager()
    private lazy var gestureMonitor = GestureMonitor(
        onPinToggleGesture: { [weak self] in self?.togglePinnedWindow() },
        onFocusToggleGesture: { [weak self] in self?.toggleFocusLock() }
    )

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let focusStateItem = NSMenuItem(title: "Focus: Off", action: nil, keyEquivalent: "")
    private let pinnedWindowItem = NSMenuItem(title: "Pinned window: None", action: nil, keyEquivalent: "")
    private let gestureItem = NSMenuItem(title: "Gestures: 3-finger tap pin, Shift+3-finger tap focus", action: nil, keyEquivalent: "")
    private lazy var toggleFocusItem = NSMenuItem(
        title: "Focus Current App",
        action: #selector(toggleFocusFromMenu),
        keyEquivalent: ""
    )
    private lazy var togglePreviewItem = NSMenuItem(
        title: "Pin Current Window",
        action: #selector(togglePreviewFromMenu),
        keyEquivalent: ""
    )
    private lazy var repinPreviewItem = NSMenuItem(
        title: "Repin Current Window",
        action: #selector(repinCurrentWindowFromMenu),
        keyEquivalent: ""
    )
    private lazy var requestScreenRecordingItem = NSMenuItem(
        title: "Request Screen Recording",
        action: #selector(requestScreenRecordingFromMenu),
        keyEquivalent: ""
    )
    private lazy var requestAccessibilityItem = NSMenuItem(
        title: "Request Accessibility",
        action: #selector(requestAccessibilityFromMenu),
        keyEquivalent: ""
    )
    private lazy var launchAtLoginItem = NSMenuItem(
        title: "Launch on Login",
        action: #selector(toggleLaunchAtLoginFromMenu),
        keyEquivalent: ""
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.reset()
        DebugLog.write("app launched pid=\(ProcessInfo.processInfo.processIdentifier) bundleID=\(Bundle.main.bundleIdentifier ?? "nil")")
        buildMenuBarUI()

        focusLockManager.onStateChange = { [weak self] in
            self?.refreshUI()
        }

        windowPinManager.onStateChange = { [weak self] in
            self?.refreshUI()
        }

        let started = gestureMonitor.start()
        if !started {
            gestureItem.title = "Gesture: unavailable on this Mac"
        }

        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        gestureMonitor.stop()
    }

    @objc
    private func toggleFocusFromMenu() {
        DebugLog.write("menu action: toggle focus")
        toggleFocusLock()
    }

    @objc
    private func togglePreviewFromMenu() {
        DebugLog.write("menu action: toggle pin")
        togglePinnedWindow()
    }

    @objc
    private func repinCurrentWindowFromMenu() {
        DebugLog.write("menu action: repin")
        windowPinManager.pinCurrentFrontmostWindow()
        refreshUI()
    }

    @objc
    private func requestScreenRecordingFromMenu() {
        DebugLog.write("menu action: request screen recording")
        windowPinManager.requestScreenCaptureAccess()
        refreshUI()
    }

    @objc
    private func requestAccessibilityFromMenu() {
        DebugLog.write("menu action: request accessibility")
        windowPinManager.requestAccessibilityAccess()
        refreshUI()
    }

    @objc
    private func toggleLaunchAtLoginFromMenu() {
        let shouldEnable = launchAtLoginManager.status == .disabled
        DebugLog.write("menu action: toggle launch at login enabled=\(shouldEnable)")
        _ = launchAtLoginManager.setEnabled(shouldEnable)
        refreshUI()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func toggleFocusLock() {
        focusLockManager.toggleCurrentFrontmostApp()
        refreshUI()
    }

    private func togglePinnedWindow() {
        windowPinManager.togglePinCurrentWindow()
        refreshUI()
    }

    private func buildMenuBarUI() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = nil
            button.title = "OFF"
            button.toolTip = "Focus Latch"
        }

        focusStateItem.isEnabled = false
        pinnedWindowItem.isEnabled = false
        gestureItem.isEnabled = false

        menu.addItem(focusStateItem)
        menu.addItem(pinnedWindowItem)
        menu.addItem(gestureItem)
        menu.addItem(.separator())
        menu.addItem(toggleFocusItem)
        menu.addItem(togglePreviewItem)
        menu.addItem(repinPreviewItem)
        menu.addItem(requestScreenRecordingItem)
        menu.addItem(requestAccessibilityItem)
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Focus Latch",
                action: #selector(quitApp),
                keyEquivalent: "q"
            )
        )

        for item in menu.items {
            item.target = self
        }

        focusStateItem.target = nil
        pinnedWindowItem.target = nil
        gestureItem.target = nil

        statusItem.menu = menu
    }

    private func refreshUI() {
        let isFocusLocked = focusLockManager.isLocked
        let lockedAppName = focusLockManager.lockedAppName
        let isPinned = windowPinManager.isPinned
        let hasPinFailure = windowPinManager.hasPinFailure
        let pinnedLabel = windowPinManager.pinnedWindowDescription

        focusStateItem.title = "Focus: \(isFocusLocked ? lockedAppName : "Off")"
        pinnedWindowItem.title = "Pinned window: \(pinnedLabel)"
        toggleFocusItem.title = isFocusLocked ? "Release Focus" : "Focus Current App"
        togglePreviewItem.title = if isPinned {
            "Release Pin"
        } else if hasPinFailure {
            "Retry Pin Current Window"
        } else {
            "Pin Current Window"
        }
        repinPreviewItem.isEnabled = true
        requestScreenRecordingItem.title = windowPinManager.hasScreenCaptureAccess ? "Screen Recording Granted" : "Request Screen Recording"
        requestScreenRecordingItem.isEnabled = !windowPinManager.hasScreenCaptureAccess
        requestAccessibilityItem.title = windowPinManager.hasAccessibilityAccess ? "Accessibility Granted" : "Request Accessibility"
        requestAccessibilityItem.isEnabled = !windowPinManager.hasAccessibilityAccess
        switch launchAtLoginManager.status {
        case .enabled:
            launchAtLoginItem.title = "Launch on Login"
            launchAtLoginItem.state = .on
        case .disabled:
            launchAtLoginItem.title = "Launch on Login"
            launchAtLoginItem.state = .off
        case .requiresApproval:
            launchAtLoginItem.title = "Launch on Login (Pending Approval)"
            launchAtLoginItem.state = .mixed
        }
        launchAtLoginItem.isEnabled = true

        statusItem?.button?.image = nil
        statusItem?.button?.title = if isFocusLocked && isPinned {
            "FOCUS+PIN"
        } else if isFocusLocked {
            "FOCUS"
        } else if isPinned {
            "PIN"
        } else if hasPinFailure {
            "PIN!"
        } else {
            "OFF"
        }
        if isFocusLocked && isPinned {
            statusItem?.button?.toolTip = "Focus Latch: focus \(lockedAppName), preview \(pinnedLabel)"
        } else if isFocusLocked {
            statusItem?.button?.toolTip = "Focus Latch: focus \(lockedAppName)"
        } else if isPinned {
            statusItem?.button?.toolTip = "Focus Latch: preview \(pinnedLabel)"
        } else if hasPinFailure {
            statusItem?.button?.toolTip = "Focus Latch: \(pinnedLabel)"
        } else {
            statusItem?.button?.toolTip = "Focus Latch"
        }
    }
}
