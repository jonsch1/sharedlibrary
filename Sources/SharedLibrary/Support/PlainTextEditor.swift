import AppKit
import SwiftUI

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    var font: NSFont
    var isEditable = true
    var focusRequest = 0
    var movesInsertionPointToEndOnFocus = false
    var textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
    var backgroundColor = NSColor.clear
    var insertionPointColor = NSColor(calibratedWhite: 0.90, alpha: 1)

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.drawsBackground = backgroundColor.alphaComponent > 0
        textView.insertionPointColor = insertionPointColor
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        context.coordinator.textView = textView
        context.coordinator.focusRequest = focusRequest
        scrollView.documentView = textView
        return scrollView
    }

    static func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: .zero)

        // TextKit 2 can get stuck estimating the viewport when this scrollable
        // editor moves the insertion point to the end. Accessing layoutManager
        // opts NSTextView into the stable TextKit 1 compatibility path.
        _ = textView.layoutManager

        return textView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        context.coordinator.text = $text
        context.coordinator.isUpdatingFromSwiftUI = true
        if textView.string != text {
            let previousSelectionLocation = textView.selectedRange().location
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(previousSelectionLocation, length), length: 0))
        }
        context.coordinator.isUpdatingFromSwiftUI = false

        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.drawsBackground = backgroundColor.alphaComponent > 0
        textView.insertionPointColor = insertionPointColor
        textView.isEditable = isEditable

        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            focusIfNeeded(textView, in: scrollView, context: context)
        }
    }

    private func focusIfNeeded(_ textView: NSTextView, in scrollView: NSScrollView, context: Context) {
        guard focusRequest > 0 else { return }
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
            if movesInsertionPointToEndOnFocus {
                let end = (textView.string as NSString).length
                let insertionPoint = NSRange(location: end, length: 0)
                textView.setSelectedRange(insertionPoint)
                textView.scrollRangeToVisible(insertionPoint)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var focusRequest = 0
        var isUpdatingFromSwiftUI = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI,
                  let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }
    }
}
