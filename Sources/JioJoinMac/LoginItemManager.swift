import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var statusText = "Checking…"
    @Published private(set) var requiresApproval = false

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            statusText = "Enabled"
            requiresApproval = false
        case .requiresApproval:
            statusText = "Approval required"
            requiresApproval = true
        case .notRegistered:
            statusText = "Disabled"
            requiresApproval = false
        case .notFound:
            statusText = "Unavailable"
            requiresApproval = false
        @unknown default:
            statusText = "Unknown"
            requiresApproval = false
        }
    }
}
