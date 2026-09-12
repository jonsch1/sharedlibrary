import SwiftUI

#if os(macOS)
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: CaptureShortcut

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onShortcut = { shortcut = $0 }
        button.displayedShortcut = shortcut
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onShortcut = { shortcut = $0 }
        button.displayedShortcut = shortcut
    }

    final class RecorderButton: NSButton {
        var onShortcut: (CaptureShortcut) -> Void = { _ in }
        var displayedShortcut = CaptureShortcut.defaultValue {
            didSet {
                if !recording { title = displayedShortcut.label }
            }
        }
        private var recording = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            title = displayedShortcut.label
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            recording = true
            title = "Press shortcut…"
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if
                event.keyCode == UInt16(kVK_Escape),
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            {
                _ = window?.makeFirstResponder(nil)
                return
            }
            guard let value = CaptureShortcut(event: event) else {
                NSSound.beep()
                return
            }
            onShortcut(value)
            _ = window?.makeFirstResponder(nil)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            title = displayedShortcut.label
            return super.resignFirstResponder()
        }
    }
}
#endif
