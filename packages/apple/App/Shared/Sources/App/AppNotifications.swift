import Foundation

extension Notification.Name {
    static let brieflyCaptureClipboard = Self("BrieflyCaptureClipboard")
    static let brieflyCaptureShortcutChanged = Self("BrieflyCaptureShortcutChanged")
    static let brieflyCaptureShortcutRegistrationChanged =
        Self("BrieflyCaptureShortcutRegistrationChanged")
    static let brieflyImportPDF = Self("BrieflyImportPDF")
    static let brieflyRefreshLibrary = Self("BrieflyRefreshLibrary")
}
