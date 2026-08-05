import SwiftUI

#if os(macOS)
import AppKit

struct EditableDocumentTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let highlightedPassages: [String]
    let onHighlight: ((String) -> Void)?
    let onRemoveHighlight: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = MarkdownTextView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 32, height: 90)
        textView.highlightAction = onHighlight
        textView.removeHighlightAction = onRemoveHighlight
        textView.highlightedPassages = highlightedPassages
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.setMarkdown(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MarkdownTextView else {
            return
        }
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.highlightAction = onHighlight
        textView.removeHighlightAction = onRemoveHighlight
        textView.highlightedPassages = highlightedPassages
        if textView.string != text { textView.setMarkdown(text) }
        else { textView.renderMarkdown() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableDocumentTextView

        init(_ parent: EditableDocumentTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else {
                return
            }
            parent.text = textView.string
            textView.renderMarkdown()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else {
                return
            }
            textView.showHighlightButton(for: textView.selectedRange())
        }
    }
}

private final class HighlightButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

private final class MarkdownTextView: NSTextView {
    var highlightAction: ((String) -> Void)?
    var removeHighlightAction: ((String) -> Void)?
    var highlightedPassages = [String]()
    private var highlightButton: NSButton?
    private var highlightedText = ""
    private var removesHighlight = false
    private var isRendering = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainerInset = NSSize(
            width: max(32, (newSize.width - 780) / 2),
            height: 90
        )
    }

    func setMarkdown(_ text: String) {
        string = text
        renderMarkdown()
    }

    func renderMarkdown() {
        guard !isRendering, let storage = textStorage else { return }
        isRendering = true
        defer { isRendering = false }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 32
        paragraph.maximumLineHeight = 32
        let body = NSFont(name: "NewYork-Regular", size: 19) ??
            .systemFont(ofSize: 19)
        let bold = NSFont(name: "NewYork-Bold", size: 19) ??
            .boldSystemFont(ofSize: 19)
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        let hidden = NSFont.systemFont(ofSize: 0.1)

        storage.beginEditing()
        applyMarkdownStyling(
            to: storage,
            text: string,
            highlightedPassages: highlightedPassages,
            baseAttributes: [
                .font: body,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ],
            attributesFor: { style in
                switch style {
                case .hidden:
                    return [.font: hidden, .foregroundColor: NSColor.clear]
                case .bold:
                    return [.font: bold]
                case .italic:
                    return [.font: italic]
                case .code:
                    return [
                        .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                        .backgroundColor: NSColor.quaternaryLabelColor
                    ]
                case .link:
                    return [
                        .foregroundColor: NSColor.controlAccentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                case .quote:
                    return [
                        .font: italic,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                case let .heading(level):
                    let size = level == 1 ? 28.0 : level == 2 ? 23.0 : 19.0
                    return [
                        .font: NSFont(name: "NewYork-Bold", size: size) ??
                            .boldSystemFont(ofSize: size)
                    ]
                }
            },
            highlightAttributes: [
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.34)
            ]
        )
        storage.endEditing()
        typingAttributes = [
            .font: body,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph
        ]
        needsDisplay = true
    }

    func showHighlightButton(for range: NSRange) {
        guard
            range.length > 0,
            highlightAction != nil,
            let textRange = Range(range, in: string)
        else {
            highlightButton?.removeFromSuperview()
            highlightButton = nil
            return
        }
        let text = String(string[textRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            highlightButton?.removeFromSuperview()
            highlightButton = nil
            return
        }
        let existingHighlight = highlightedPassage(
            in: string as NSString,
            passages: highlightedPassages,
            intersecting: range
        )
        removesHighlight = existingHighlight != nil
        highlightedText = existingHighlight ?? text

        let button = highlightButton ?? HighlightButton(
            title: "",
            target: self,
            action: #selector(toggleHighlight)
        )
        button.title = ""
        button.image = NSImage(
            systemSymbolName: removesHighlight ? "eraser" : "highlighter",
            accessibilityDescription: nil
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .none
        button.contentTintColor = removesHighlight
            ? NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.12, alpha: 1)
            : NSColor(calibratedRed: 0.58, green: 0.36, blue: 0.02, alpha: 1)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.cgColor
        button.layer?.borderColor = NSColor(
            calibratedWhite: 0.78,
            alpha: 1
        ).cgColor
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = 9
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.16
        button.layer?.shadowRadius = 5
        button.layer?.shadowOffset = CGSize(width: 0, height: -2)
        button.setAccessibilityLabel(
            removesHighlight
                ? "Remove selection from Highlights"
                : "Add selection to Highlights"
        )
        button.toolTip = removesHighlight
            ? "Remove selection from Highlights"
            : "Add selection to Highlights"
        if highlightButton == nil {
            addSubview(button, positioned: .above, relativeTo: nil)
            highlightButton = button
        }

        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        var selectionRect = layoutManager.boundingRect(
            forGlyphRange: glyphs,
            in: textContainer
        )
        selectionRect.origin.x += textContainerOrigin.x
        selectionRect.origin.y += textContainerOrigin.y
        let size = NSSize(width: 34, height: 34)
        let x = min(
            max(selectionRect.midX - size.width / 2, visibleRect.minX + 6),
            visibleRect.maxX - size.width - 6
        )
        let above = selectionRect.minY - size.height - 10
        let y = above >= visibleRect.minY + 4
            ? above
            : min(selectionRect.maxY + 10, visibleRect.maxY - size.height - 4)
        button.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    @objc private func toggleHighlight() {
        if removesHighlight {
            removeHighlightAction?(highlightedText)
        } else {
            highlightAction?(highlightedText)
        }
        highlightButton?.removeFromSuperview()
        highlightButton = nil
    }
}
#endif
