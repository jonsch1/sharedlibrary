import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens or hides Shared Library. Default ⌥⇧Space.
    static let toggleLibrary = Self("toggleLibrary", default: .init(.space, modifiers: [.option, .shift]))
    /// Captures the clipboard into the source library. Default ⌘G.
    static let captureClipboard = Self("captureClipboard", default: .init(.g, modifiers: [.command]))
}
