@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreMedia
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowPinManager {
    struct PinnedWindow {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let ownerName: String
        let title: String
        let bounds: CGRect
    }

    private enum PinState {
        case idle
        case starting
        case active(description: String)
        case failed(message: String)
    }

    private let workspace = NSWorkspace.shared
    private let ignoredBundleIdentifier: String?
    private var activationObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private var panel: NSPanel?
    private var previewView: PreviewStreamView?
    private var refreshTimer: Timer?
    private var stream: SCStream?
    private var streamOutput: StreamOutputProxy?
    private var pinState: PinState = .idle
    private var passthroughMonitorTimer: Timer?
    private var isPassthroughActive = false

    private(set) var pinnedWindow: PinnedWindow?
    var onStateChange: (() -> Void)?

    var isPinned: Bool {
        if case .active = pinState {
            return true
        }

        return false
    }

    var hasPinFailure: Bool {
        if case .failed = pinState {
            return true
        }

        return false
    }

    var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    var pinnedWindowDescription: String {
        switch pinState {
        case .idle:
            return "None"
        case .starting:
            return "Starting pin..."
        case let .active(description):
            return description
        case let .failed(message):
            return message
        }
    }

    init(ignoredBundleIdentifier: String?) {
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        observeWorkspaceNotifications()
    }

    func togglePinCurrentWindow() {
        if isPinned {
            unpin()
        } else {
            pinCurrentFrontmostWindow()
        }
    }

    func pinCurrentFrontmostWindow() {
        let hasAccessibilityAccess = hasAccessibilityAccess

        guard let app = currentPinCandidate() else {
            updatePinState(.failed(message: "No capturable window"))
            return
        }

        updatePinState(.starting)
        pin(application: app, hasAccessibilityAccess: hasAccessibilityAccess)
    }

    func unpin() {
        tearDownPinResources()
        updatePinState(.idle)
    }

    func requestScreenCaptureAccess() {
        guard !hasScreenCaptureAccess else {
            updatePinState(.failed(message: "Screen Recording already granted"))
            return
        }

        openScreenCaptureSettings()
        updatePinState(.failed(message: "Grant Screen Recording in Settings"))
    }

    func requestAccessibilityAccess() {
        guard !hasAccessibilityAccess else {
            updatePinState(.failed(message: "Accessibility already granted"))
            return
        }

        _ = ensureAccessibilityPermission(promptIfNeeded: true)
        updatePinState(.failed(message: "Grant Accessibility in Settings"))
    }

    private func pin(application: NSRunningApplication, hasAccessibilityAccess: Bool) {
        Task { [weak self] in
            await self?.startPinning(application, hasAccessibilityAccess: hasAccessibilityAccess)
        }
    }

    private func startPinning(_ application: NSRunningApplication, hasAccessibilityAccess: Bool) async {
        do {
            let (window, shareableWindow) = try await resolvePinTarget(for: application)
            let panel = ensurePanel()
            endPassthrough()
            updatePanelFrame(panel, bounds: window.bounds)
            previewView?.clear()

            try await startOrUpdateStream(for: window, shareableWindow: shareableWindow)

            pinnedWindow = window
            panel.orderFrontRegardless()
            // Keep the target app active; the panel is only a non-activating mirror.
            NSRunningApplication(processIdentifier: window.ownerPID)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            startRefreshTimer()
            updatePinState(.active(description: description(for: window, hasAccessibilityAccess: hasAccessibilityAccess)))
        } catch PreviewError.windowUnavailable {
            tearDownPinResources()
            updatePinState(.failed(message: "Window not shareable"))
        } catch {
            tearDownPinResources()
            updatePinState(.failed(message: failureMessage(for: error)))
        }
    }

    private func currentPinCandidate() -> NSRunningApplication? {
        if let frontmost = workspace.frontmostApplication,
           frontmost.bundleIdentifier != ignoredBundleIdentifier {
            return frontmost
        }

        if let lastExternalApplication,
           !lastExternalApplication.isTerminated,
           lastExternalApplication.bundleIdentifier != ignoredBundleIdentifier {
            return lastExternalApplication
        }

        return nil
    }

    private func observeWorkspaceNotifications() {
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self,
                      let application,
                      application.bundleIdentifier != self.ignoredBundleIdentifier else {
                    return
                }

                self.lastExternalApplication = application
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = PreviewPanel(
            contentRect: NSRect(x: 160, y: 140, width: 900, height: 700),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false

        let previewView = PreviewStreamView(frame: panel.contentView?.bounds ?? .zero)
        previewView.autoresizingMask = [.width, .height]
        previewView.onHoverInside = { [weak self] in
            self?.activateSourceAndBeginPassthrough()
        }
        previewView.onMouseEvent = { [weak self] event, view in
            self?.handleFirstClickOnPreview(event, from: view)
        }
        previewView.onScrollEvent = { [weak self] _, _ in
            self?.activateSourceAndBeginPassthrough()
        }
        panel.contentView?.addSubview(previewView)

        self.panel = panel
        self.previewView = previewView
        return panel
    }

    private func updatePanelFrame(_ panel: NSPanel, bounds: CGRect) {
        let panelFrame = panelFrame(for: bounds)
        panel.setFrame(panelFrame, display: true)
        previewView?.frame = NSRect(origin: .zero, size: panelFrame.size)
    }

    private func panelFrame(for windowBounds: CGRect) -> NSRect {
        let desktopFrame = NSScreen.screens.reduce(into: CGRect.null) { result, screen in
            result = result.union(screen.frame)
        }
        let origin = NSPoint(
            x: windowBounds.origin.x,
            y: desktopFrame.maxY - windowBounds.origin.y - windowBounds.height
        )
        let size = NSSize(width: max(1, windowBounds.width), height: max(1, windowBounds.height))
        return NSRect(origin: origin, size: size)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPinnedWindow()
            }
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func refreshPinnedWindow() {
        guard let pinnedWindow else {
            return
        }

        guard let latestWindow = currentWindowInfo(for: pinnedWindow.windowID) else {
            tearDownPinResources()
            updatePinState(.failed(message: "Preview source unavailable"))
            return
        }

        self.pinnedWindow = latestWindow
        updatePinState(.active(description: description(for: latestWindow, hasAccessibilityAccess: hasAccessibilityAccess)))

        if let panel {
            updatePanelFrame(panel, bounds: latestWindow.bounds)
        }

        Task { [weak self] in
            await self?.updateStreamConfiguration(for: latestWindow)
        }

        onStateChange?()
    }

    private func startOrUpdateStream(for window: PinnedWindow, shareableWindow: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let configuration = makeStreamConfiguration(for: window.bounds)

        if let stream {
            try await stream.updateContentFilter(filter)
            try await stream.updateConfiguration(configuration)
            return
        }

        let output = StreamOutputProxy(
            targetLayer: previewView?.sampleBufferLayer,
            onStop: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleStreamStop(error)
                }
            }
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output
    }

    private func updateStreamConfiguration(for window: PinnedWindow) async {
        guard let stream else {
            return
        }

        let configuration = makeStreamConfiguration(for: window.bounds)
        try? await stream.updateConfiguration(configuration)
    }

    private func makeStreamConfiguration(for bounds: CGRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scaleFactor = screenScaleFactor(for: bounds)
        configuration.width = Int(max(1, round(bounds.width * scaleFactor)))
        configuration.height = Int(max(1, round(bounds.height * scaleFactor)))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.scalesToFit = true

        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
        }

        return configuration
    }

    private func resolvePinTarget(for app: NSRunningApplication) async throws -> (PinnedWindow, SCWindow) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let shareableWindows = content.windows.filter { window in
            guard let owningApplication = window.owningApplication else {
                return false
            }

            return owningApplication.processID == app.processIdentifier &&
                window.windowLayer == 0 &&
                window.frame.width > 120 &&
                window.frame.height > 100 &&
                window.isOnScreen
        }

        guard !shareableWindows.isEmpty else {
            throw PreviewError.windowUnavailable
        }

        let cgCandidates = currentWindowCandidates(for: app)

        for candidate in cgCandidates {
            if let shareableWindow = shareableWindows.first(where: { $0.windowID == candidate.windowID }) {
                DebugLog.write("resolvePinTarget exact-match pid=\(app.processIdentifier) windowID=\(candidate.windowID)")
                return (candidate, shareableWindow)
            }
        }

        if let activeShareableWindow = shareableWindows.first(where: { windowIsActive($0) }) {
            let pinnedWindow = makePinnedWindow(from: activeShareableWindow, fallbackApp: app)
            DebugLog.write("resolvePinTarget active-scwindow pid=\(app.processIdentifier) windowID=\(pinnedWindow.windowID)")
            return (pinnedWindow, activeShareableWindow)
        }

        if let matchedTarget = bestPinTarget(from: shareableWindows, cgCandidates: cgCandidates, app: app) {
            DebugLog.write("resolvePinTarget scored-match pid=\(app.processIdentifier) windowID=\(matchedTarget.0.windowID)")
            return matchedTarget
        }

        guard let fallbackShareableWindow = shareableWindows.first else {
            throw PreviewError.windowUnavailable
        }

        let pinnedWindow = makePinnedWindow(from: fallbackShareableWindow, fallbackApp: app)
        DebugLog.write("resolvePinTarget fallback-scwindow pid=\(app.processIdentifier) windowID=\(pinnedWindow.windowID)")
        return (pinnedWindow, fallbackShareableWindow)
    }

    private func handleStreamStop(_ error: Error?) {
        if case .idle = pinState {
            return
        }

        tearDownPinResources()
        updatePinState(.failed(message: error == nil ? "Preview stopped" : "Preview stream failed"))
    }

    private func currentWindowCandidates(for app: NSRunningApplication) -> [PinnedWindow] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var candidates: [PinnedWindow] = []

        for windowInfo in windows {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == app.processIdentifier,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = windowInfo[kCGWindowAlpha as String] as? Double,
                  alpha > 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 120,
                  bounds.height > 100,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? UInt32 else {
                continue
            }

            let title = (windowInfo[kCGWindowName as String] as? String) ?? ""
            let ownerName = (windowInfo[kCGWindowOwnerName as String] as? String) ?? (app.localizedName ?? "Window")

            candidates.append(
                PinnedWindow(
                windowID: CGWindowID(windowNumber),
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title,
                bounds: bounds
                )
            )
        }

        return candidates
    }

    private func currentWindowInfo(for windowID: CGWindowID) -> PinnedWindow? {
        guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windows {
            guard let currentWindowNumber = windowInfo[kCGWindowNumber as String] as? UInt32,
                  currentWindowNumber == windowID,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }

            let title = (windowInfo[kCGWindowName as String] as? String) ?? ""
            let ownerName = (windowInfo[kCGWindowOwnerName as String] as? String) ?? "Window"

            return PinnedWindow(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title,
                bounds: bounds
            )
        }

        return nil
    }

    private func screenScaleFactor(for bounds: CGRect) -> CGFloat {
        let midpoint = CGPoint(x: bounds.midX, y: bounds.midY)

        for screen in NSScreen.screens where screen.frame.contains(midpoint) {
            return screen.backingScaleFactor
        }

        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func ensureAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openAccessibilitySettings()
        }

        return false
    }

    private func handleFirstClickOnPreview(_ event: NSEvent, from view: PreviewStreamView) {
        _ = event
        _ = view
        activateSourceAndBeginPassthrough()
    }

    private func activateSourceAndBeginPassthrough() {
        guard let pinnedWindow,
              let panel else {
            return
        }

        raiseSourceWindow(pinnedWindow)

        guard !isPassthroughActive else {
            return
        }

        isPassthroughActive = true
        panel.level = .normal
        panel.ignoresMouseEvents = true
        panel.orderBack(nil)
        DebugLog.write("passthrough begin pid=\(pinnedWindow.ownerPID) windowID=\(pinnedWindow.windowID)")
        startPassthroughExitMonitor()
    }

    private func startPassthroughExitMonitor() {
        passthroughMonitorTimer?.invalidate()

        passthroughMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPassthroughExit()
            }
        }

        if let passthroughMonitorTimer {
            RunLoop.main.add(passthroughMonitorTimer, forMode: .common)
        }
    }

    private func checkPassthroughExit() {
        guard let panel else {
            endPassthrough()
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let forgivingFrame = panel.frame.insetBy(dx: -8, dy: -8)

        if !forgivingFrame.contains(mouseLocation) {
            endPassthrough()
        }
    }

    private func endPassthrough() {
        passthroughMonitorTimer?.invalidate()
        passthroughMonitorTimer = nil

        isPassthroughActive = false
        if let panel {
            panel.ignoresMouseEvents = false
            panel.level = .floating

            if pinnedWindow != nil {
                panel.orderFrontRegardless()
            }
        }
        DebugLog.write("passthrough end")
    }

    private func raiseSourceWindow(_ window: PinnedWindow) {
        NSRunningApplication(processIdentifier: window.ownerPID)?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        guard hasAccessibilityAccess else {
            return
        }

        let appElement = AXUIElementCreateApplication(window.ownerPID)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.1)

        guard let axWindow = bestAXWindow(for: window, in: appElement) else {
            DebugLog.write("raiseSourceWindow no-match pid=\(window.ownerPID) title=\(window.title)")
            return
        }

        let raiseError = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        if raiseError != .success {
            DebugLog.write("raiseSourceWindow raise failed pid=\(window.ownerPID) error=\(raiseError.rawValue)")
        }

        _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, axWindow)
    }

    private func bestAXWindow(for pinnedWindow: PinnedWindow, in appElement: AXUIElement) -> AXUIElement? {
        var rawWindows: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement],
        !windows.isEmpty else {
            return nil
        }

        let candidates = windows.compactMap { window -> (window: AXUIElement, distance: CGFloat)? in
            guard let bounds = axBounds(of: window) else {
                return nil
            }

            let distance =
                abs(bounds.minX - pinnedWindow.bounds.minX) +
                abs(bounds.minY - pinnedWindow.bounds.minY) +
                abs(bounds.width - pinnedWindow.bounds.width) +
                abs(bounds.height - pinnedWindow.bounds.height)

            return (window, distance)
        }

        if let best = candidates.min(by: { $0.distance < $1.distance }),
           best.distance < 180 {
            return best.window
        }

        if !pinnedWindow.title.isEmpty {
            for window in windows where axStringAttribute(kAXTitleAttribute as CFString, from: window) == pinnedWindow.title {
                return window
            }
        }

        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success,
           let focusedWindow,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            return unsafeDowncast(focusedWindow, to: AXUIElement.self)
        }

        return windows.first
    }

    private func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axBounds(of element: AXUIElement) -> CGRect? {
        guard let position = axPointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = axSizeAttribute(kAXSizeAttribute as CFString, from: element) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func axPointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let typedValue = unsafeDowncast(axValue, to: AXValue.self)
        guard AXValueGetType(typedValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(typedValue, .cgPoint, &point) ? point : nil
    }

    private func axSizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let typedValue = unsafeDowncast(axValue, to: AXValue.self)
        guard AXValueGetType(typedValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(typedValue, .cgSize, &size) ? size : nil
    }

    private func description(for window: PinnedWindow, hasAccessibilityAccess: Bool) -> String {
        let baseDescription: String
        if window.title.isEmpty {
            baseDescription = window.ownerName
        } else {
            baseDescription = "\(window.ownerName) - \(window.title)"
        }

        if hasAccessibilityAccess {
            return baseDescription
        }

        return "\(baseDescription) (grant Accessibility for click-through)"
    }

    private func bestPinTarget(
        from shareableWindows: [SCWindow],
        cgCandidates: [PinnedWindow],
        app: NSRunningApplication
    ) -> (PinnedWindow, SCWindow)? {
        guard !shareableWindows.isEmpty else {
            return nil
        }

        let normalizedCGCandidates = cgCandidates.map { candidate in
            (
                candidate: candidate,
                title: candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }

        var bestMatch: (PinnedWindow, SCWindow)?
        var bestScore = CGFloat.leastNormalMagnitude

        for shareableWindow in shareableWindows {
            let shareableTitle = (shareableWindow.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            var score = CGFloat(0)

            if windowIsActive(shareableWindow) {
                score += 1_000
            }

            if let matchedCandidate = normalizedCGCandidates.max(by: { lhs, rhs in
                matchScore(
                    shareableWindow: shareableWindow,
                    shareableTitle: shareableTitle,
                    candidate: lhs.candidate,
                    candidateTitle: lhs.title
                ) < matchScore(
                    shareableWindow: shareableWindow,
                    shareableTitle: shareableTitle,
                    candidate: rhs.candidate,
                    candidateTitle: rhs.title
                )
            }) {
                let candidateScore = matchScore(
                    shareableWindow: shareableWindow,
                    shareableTitle: shareableTitle,
                    candidate: matchedCandidate.candidate,
                    candidateTitle: matchedCandidate.title
                )
                score += candidateScore

                if score > bestScore {
                    bestScore = score
                    bestMatch = (matchedCandidate.candidate, shareableWindow)
                }
                continue
            }

            if score > bestScore {
                bestScore = score
                bestMatch = (makePinnedWindow(from: shareableWindow, fallbackApp: app), shareableWindow)
            }
        }

        return bestMatch
    }

    private func matchScore(
        shareableWindow: SCWindow,
        shareableTitle: String,
        candidate: PinnedWindow,
        candidateTitle: String
    ) -> CGFloat {
        var score = CGFloat(0)

        if !shareableTitle.isEmpty && shareableTitle == candidateTitle {
            score += 800
        }

        let frame = shareableWindow.frame
        let distance =
            abs(frame.minX - candidate.bounds.minX) +
            abs(frame.minY - candidate.bounds.minY) +
            abs(frame.width - candidate.bounds.width) +
            abs(frame.height - candidate.bounds.height)

        score -= distance

        if distance < 80 {
            score += 200
        }

        if shareableWindow.windowID == candidate.windowID {
            score += 10_000
        }

        return score
    }

    private func makePinnedWindow(from shareableWindow: SCWindow, fallbackApp: NSRunningApplication) -> PinnedWindow {
        let ownerPID = shareableWindow.owningApplication?.processID ?? fallbackApp.processIdentifier
        let ownerName = shareableWindow.owningApplication?.applicationName ?? (fallbackApp.localizedName ?? "Window")

        return PinnedWindow(
            windowID: shareableWindow.windowID,
            ownerPID: ownerPID,
            ownerName: ownerName,
            title: shareableWindow.title ?? "",
            bounds: shareableWindow.frame
        )
    }

    private func windowIsActive(_ window: SCWindow) -> Bool {
        if #available(macOS 13.1, *) {
            return window.isActive
        }

        return false
    }

    private func tearDownPinResources() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        passthroughMonitorTimer?.invalidate()
        passthroughMonitorTimer = nil
        isPassthroughActive = false
        panel?.ignoresMouseEvents = false

        let activeStream = stream
        let activeOutput = streamOutput

        stream = nil
        streamOutput = nil
        pinnedWindow = nil

        previewView?.clear()
        panel?.orderOut(nil)
        panel = nil
        previewView = nil

        if let activeStream, let activeOutput {
            Task {
                try? activeStream.removeStreamOutput(activeOutput, type: .screen)
                try? await activeStream.stopCapture()
            }
        }
    }

    private func updatePinState(_ newState: PinState) {
        pinState = newState
        onStateChange?()
    }

    private func failureMessage(for error: Error) -> String {
        let nsError = error as NSError
        let details = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        if details.isEmpty || details == "The operation couldn’t be completed." {
            return "Preview stream failed (\(nsError.domain) \(nsError.code))"
        }

        return "Preview stream failed: \(details)"
    }

    private func openAccessibilitySettings() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }

    private func openScreenCaptureSettings() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PreviewStreamView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var trackingArea: NSTrackingArea?
    var onHoverInside: (() -> Void)?
    var onMouseEvent: ((NSEvent, PreviewStreamView) -> Void)?
    var onScrollEvent: ((NSEvent, PreviewStreamView) -> Void)?

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        displayLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )

        self.trackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        _ = event
        onHoverInside?()
    }

    override func mouseMoved(with event: NSEvent) {
        _ = event
        onHoverInside?()
    }

    override func mouseDown(with event: NSEvent) {
        onHoverInside?()
        onMouseEvent?(event, self)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseEvent?(event, self)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseEvent?(event, self)
    }

    override func rightMouseDown(with event: NSEvent) {
        onHoverInside?()
        onMouseEvent?(event, self)
    }

    override func rightMouseUp(with event: NSEvent) {
        onMouseEvent?(event, self)
    }

    override func rightMouseDragged(with event: NSEvent) {
        onMouseEvent?(event, self)
    }

    override func otherMouseDown(with event: NSEvent) {
        onHoverInside?()
        onMouseEvent?(event, self)
    }

    override func otherMouseUp(with event: NSEvent) {
        onMouseEvent?(event, self)
    }

    override func otherMouseDragged(with event: NSEvent) {
        onMouseEvent?(event, self)
    }

    override func scrollWheel(with event: NSEvent) {
        onHoverInside?()
        onScrollEvent?(event, self)
    }

    func display(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return
        }

        displayLayer.enqueue(sampleBuffer)
    }

    func clear() {
        displayLayer.flushAndRemoveImage()
    }
}

private final class StreamOutputProxy: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var targetLayer: AVSampleBufferDisplayLayer?
    private let onStop: (Error?) -> Void

    init(
        targetLayer: AVSampleBufferDisplayLayer?,
        onStop: @escaping (Error?) -> Void
    ) {
        self.targetLayer = targetLayer
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else {
            return
        }

        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return
        }

        targetLayer?.enqueue(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

private enum PreviewError: Error {
    case windowUnavailable
}
