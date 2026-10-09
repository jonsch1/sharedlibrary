import Foundation

extension Notification.Name {
    static let brieflyCaptureClipboard = Self("BrieflyCaptureClipboard")
    static let brieflyCaptureShortcutChanged = Self("BrieflyCaptureShortcutChanged")
    static let brieflyCaptureShortcutRegistrationChanged =
        Self("BrieflyCaptureShortcutRegistrationChanged")
    static let brieflyImportFile = Self("BrieflyImportFile")
    static let brieflyRefreshLibrary = Self("BrieflyRefreshLibrary")
    static let brieflyOpenCaptureComposer = Self("BrieflyOpenCaptureComposer")
    static let brieflyOpenSettings = Self("BrieflyOpenSettings")
    static let brieflyNavigateBack = Self("BrieflyNavigateBack")
    static let brieflyFocusSearch = Self("BrieflyFocusSearch")
}
