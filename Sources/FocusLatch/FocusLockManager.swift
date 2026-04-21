@preconcurrency import AppKit

final class FocusLockManager {
    private let workspace = NSWorkspace.shared
    private let ignoredBundleIdentifier: String?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var reactivationWorkItem: DispatchWorkItem?
    private var lastExternalApplication: NSRunningApplication?

    private(set) var lockedApplication: NSRunningApplication?
    var onStateChange: (() -> Void)?

    var isLocked: Bool {
        lockedApplication != nil
    }

    var lockedAppName: String {
        lockedApplication?.localizedName ?? "None"
    }

    init(ignoredBundleIdentifier: String?) {
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        observeWorkspaceNotifications()
    }

    deinit {
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
        }

        if let terminationObserver {
            workspace.notificationCenter.removeObserver(terminationObserver)
        }
    }

    func toggleCurrentFrontmostApp() {
        if isLocked {
            unlock()
        } else {
            lockCurrentFrontmostApp()
        }
    }

    func lockCurrentFrontmostApp() {
        guard let application = currentLockCandidate() else {
            return
        }

        lock(application)
    }

    func unlock() {
        reactivationWorkItem?.cancel()
        reactivationWorkItem = nil
        lockedApplication = nil
        onStateChange?()
    }

    private func lock(_ application: NSRunningApplication) {
        guard application.bundleIdentifier != ignoredBundleIdentifier else {
            return
        }

        lockedApplication = application
        lastExternalApplication = application
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        onStateChange?()
    }

    private func currentLockCandidate() -> NSRunningApplication? {
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
            self?.handleActivation(notification)
        }

        terminationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            self?.handleTermination(notification)
        }
    }

    private func handleActivation(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        if application.bundleIdentifier != ignoredBundleIdentifier {
            lastExternalApplication = application
        }

        guard let lockedApplication else {
            return
        }

        if application.processIdentifier == lockedApplication.processIdentifier {
            return
        }

        if lockedApplication.isTerminated {
            unlock()
            return
        }

        scheduleReactivation(of: lockedApplication)
    }

    private func handleTermination(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let lockedApplication else {
            return
        }

        if application.processIdentifier == lockedApplication.processIdentifier {
            unlock()
        }
    }

    private func scheduleReactivation(of application: NSRunningApplication) {
        reactivationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            guard let lockedApplication = self.lockedApplication,
                  lockedApplication.processIdentifier == application.processIdentifier,
                  !lockedApplication.isTerminated else {
                self.unlock()
                return
            }

            lockedApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        reactivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }
}
