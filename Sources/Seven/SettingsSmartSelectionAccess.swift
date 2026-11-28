import SwiftUI

@MainActor @Observable
final class SettingsSmartSelectionAccess {
    private let isTrusted: () -> Bool
    private let requestPermission: @MainActor (@escaping () -> Void) -> Void
    private let refreshPermissionRequest: @MainActor () -> Void
    private(set) var isGranted: Bool

    convenience init() {
        self.init(isTrusted: { SelectionReader.isAccessibilityTrusted }, requestPermission: { onGranted in
            AppAlert.confirmPermission(.accessibility, present: { AppAlert.runModal($0) }, authorize: { permission in
                PermissionGuide.shared.authorize(permission, onGranted: onGranted)
            })
        }, refreshPermissionRequest: { PermissionGuide.shared.refreshPermission() })
    }

    init(isTrusted: @escaping () -> Bool,
         requestPermission: @escaping @MainActor (@escaping () -> Void) -> Void,
         refreshPermissionRequest: @escaping @MainActor () -> Void = {}) {
        self.isTrusted = isTrusted
        self.requestPermission = requestPermission
        self.refreshPermissionRequest = refreshPermissionRequest
        isGranted = isTrusted()
    }

    func refresh() {
        // Complete the already-authorized enable request first before letting the user interact with the refreshed toggle.
        refreshPermissionRequest()
        isGranted = isTrusted()
    }

    func binding(for preference: Binding<Bool>) -> Binding<Bool> {
        // Register the Observation dependency on permission state while constructing the binding.
        let _ = isGranted
        return Binding(get: { self.isGranted && preference.wrappedValue }, set: { enabled in
            self.refresh()
            if self.isGranted {
                preference.wrappedValue = enabled
                return
            }
            guard enabled else { return }
            self.requestPermission { [weak self] in
                guard let self else { return }
                let granted = isTrusted()
                if granted { preference.wrappedValue = true }
                isGranted = granted
            }
        })
    }
}
