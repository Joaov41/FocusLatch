import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager {
    enum Status {
        case enabled
        case disabled
        case requiresApproval
    }

    private let appService = SMAppService.mainApp

    var status: Status {
        switch appService.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if appService.status == .enabled || appService.status == .requiresApproval {
                    return true
                }

                try appService.register()
            } else {
                if appService.status == .notRegistered || appService.status == .notFound {
                    return true
                }

                try appService.unregister()
            }

            DebugLog.write("launch at login updated enabled=\(enabled) status=\(String(describing: appService.status.rawValue))")
            return true
        } catch {
            DebugLog.write("launch at login update failed enabled=\(enabled) error=\(error.localizedDescription)")
            return false
        }
    }
}
