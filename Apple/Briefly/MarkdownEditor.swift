import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif
private enum MarkdownRunStyle {
    case hidden
    case bold
    case italic
    case code
    case link
    case quote
    case heading(Int)
}

private func markdownRuns(in text: String) -> [(NSRange, MarkdownRunStyle)] {
    let fullRange = NSRange(location: 0, length: text.utf16.count)
    var runs = [(NSRange, MarkdownRunStyle)]()

    func matches(_ pattern: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern))?.matches(
            in: text,
            range: fullRange
        ) ?? []
    }

    func addWrapped(_ match: NSTextCheckingResult, content: NSRange) {
        guard content.location != NSNotFound else { return }
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        let suffix = NSRange(
            location: NSMaxRange(content),
            length: NSMaxRange(match.range) - NSMaxRange(content)
        )
        if prefix.length > 0 { runs.append((prefix, .hidden)) }
        if suffix.length > 0 { runs.append((suffix, .hidden)) }
    }

    for match in matches(#"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#) {
        let content = match.range(at: 1).location == NSNotFound
            ? match.range(at: 2)
            : match.range(at: 1)
        runs.append((content, .bold))
        addWrapped(match, content: content)
    }
    for match in matches(#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#) {
        let content = match.range(at: 1).location == NSNotFound
            ? match.range(at: 2)
            : match.range(at: 1)
        runs.append((content, .italic))
        addWrapped(match, content: content)
    }
    for match in matches(#"`([^`\n]+)`"#) {
        let content = match.range(at: 1)
        runs.append((content, .code))
        addWrapped(match, content: content)
    }
    for match in matches(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#) {
        let label = match.range(at: 1)
        runs.append((label, .link))
        addWrapped(match, content: label)
    }
    for match in matches(#"(?m)^>[ \t]+([^\n]*)$"#) {
        let content = match.range(at: 1)
        runs.append((content, .quote))
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        runs.append((prefix, .hidden))
    }
    for match in matches(#"(?m)^(#{1,3})[ \t]+([^\n]+)$"#) {
        let marker = match.range(at: 1)
        let content = match.range(at: 2)
        runs.append((content, .heading(marker.length)))
        let prefix = NSRange(
            location: match.range.location,
            length: content.location - match.range.location
        )
        runs.append((prefix, .hidden))
    }
    return runs
}

func highlightedPassages(in markdown: String) -> [String] {
    var passages = [String]()
    var quote = [String]()
    for line in markdown.components(separatedBy: .newlines) + [""] {
        if line.hasPrefix("> ") {
            quote.append(String(line.dropFirst(2)))
        } else if !quote.isEmpty {
            passages.append(quote.joined(separator: "\n"))
            quote.removeAll(keepingCapacity: true)
        }
    }
    return passages
}

private func highlightedPassage(
    in source: NSString,
    passages: [String],
    intersecting selection: NSRange
) -> String? {
    for passage in passages where !passage.isEmpty {
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: passage, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if NSIntersectionRange(found, selection).length > 0 { return passage }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: source.length - next)
        }
    }
    return nil
}

struct DocumentEditor: View {
    @Bindable var model: LibraryModel
    let entryID: String
    let variant: LibraryVariant
    let sourceText: String
    let highlightedPassages: [String]
    let isEditing: Bool
    @State private var draft: String
    @State private var pendingSave: Task<Void, Never>?

    init(
        model: LibraryModel,
        entryID: String,
        variant: LibraryVariant,
        sourceText: String,
        highlightedPassages: [String],
        isEditing: Bool
    ) {
        self.model = model
        self.entryID = entryID
        self.variant = variant
        self.sourceText = sourceText
        self.highlightedPassages = highlightedPassages
        self.isEditing = isEditing
        _draft = State(initialValue: sourceText)
    }

    var body: some View {
        EditableDocumentTextView(
            text: $draft,
            isEditable: model.canEdit && !model.showingTrash && isEditing,
            highlightedPassages: highlightedPassages,
            onHighlight: model.canEdit && !model.showingTrash ? { text in
                Task { await model.addHighlight(text) }
            } : nil,
            onRemoveHighlight: model.canEdit && !model.showingTrash ? { text in
                Task { await model.removeHighlight(text) }
            } : nil
        )
        .onChange(of: sourceText) { oldValue, newValue in
            if draft == oldValue { draft = newValue }
        }
        .onChange(of: draft) {
            guard model.canEdit, !model.showingTrash, isEditing, draft != sourceText else {
                return
            }
            pendingSave?.cancel()
            let text = draft
            pendingSave = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await model.saveText(text, entryID: entryID, variant: variant)
            }
        }
    }
}

#if os(macOS)
private struct EditableDocumentTextView: NSViewRepresentable {
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
        let range = NSRange(location: 0, length: string.utf16.count)
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
        storage.setAttributes(
            [
                .font: body,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ],
            range: range
        )
        for (range, style) in markdownRuns(in: string) {
            let attributes: [NSAttributedString.Key: Any]
            switch style {
            case .hidden:
                attributes = [.font: hidden, .foregroundColor: NSColor.clear]
            case .bold:
                attributes = [.font: bold]
            case .italic:
                attributes = [.font: italic]
            case .code:
                attributes = [
                    .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor
                ]
            case .link:
                attributes = [
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            case .quote:
                attributes = [
                    .font: italic,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            case let .heading(level):
                let size = level == 1 ? 28.0 : level == 2 ? 23.0 : 19.0
                attributes = [
                    .font: NSFont(name: "NewYork-Bold", size: size) ??
                        .boldSystemFont(ofSize: size)
                ]
            }
            storage.addAttributes(attributes, range: range)
        }
        let source = string as NSString
        for passage in highlightedPassages where !passage.isEmpty {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(of: passage, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                storage.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.34),
                    range: found
                )
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }
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
#elseif os(iOS)
private struct EditableDocumentTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let highlightedPassages: [String]
    let onHighlight: ((String) -> Void)?
    let onRemoveHighlight: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(
            top: 90,
            left: 32,
            bottom: 240,
            right: 32
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.highlightedPassages = highlightedPassages
        textView.setMarkdown(text)
        return textView
    }

    func updateUIView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.highlightedPassages = highlightedPassages
        if textView.text != text { textView.setMarkdown(text) }
        else { textView.renderMarkdown() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditableDocumentTextView

        init(_ parent: EditableDocumentTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? MarkdownTextView)?.renderMarkdown()
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard
                range.length > 0,
                parent.onHighlight != nil
            else { return UIMenu(children: suggestedActions) }
            let text = (textView.text as NSString).substring(with: range)
            let existingHighlight = highlightedPassage(
                in: textView.text as NSString,
                passages: parent.highlightedPassages,
                intersecting: range
            )
            let action = UIAction(
                title: existingHighlight == nil ? "Highlight" : "Remove Highlight",
                image: UIImage(
                    systemName: existingHighlight == nil ? "highlighter" : "eraser"
                )
            ) { _ in
                if let existingHighlight {
                    self.parent.onRemoveHighlight?(existingHighlight)
                } else {
                    self.parent.onHighlight?(text)
                }
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}

private final class MarkdownTextView: UITextView {
    var highlightedPassages = [String]()
    private var isRendering = false

    func setMarkdown(_ markdown: String) {
        text = markdown
        renderMarkdown()
    }

    func renderMarkdown() {
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }
        let range = NSRange(location: 0, length: text.utf16.count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 32
        paragraph.maximumLineHeight = 32
        let body = UIFont(name: "NewYork-Regular", size: 19) ??
            .systemFont(ofSize: 19)
        let bold = UIFont(name: "NewYork-Bold", size: 19) ??
            .boldSystemFont(ofSize: 19)
        let italic = UIFont.italicSystemFont(ofSize: 19)
        let hidden = UIFont.systemFont(ofSize: 0.1)

        textStorage.beginEditing()
        textStorage.setAttributes(
            [
                .font: body,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ],
            range: range
        )
        for (range, style) in markdownRuns(in: text) {
            let attributes: [NSAttributedString.Key: Any]
            switch style {
            case .hidden:
                attributes = [.font: hidden, .foregroundColor: UIColor.clear]
            case .bold:
                attributes = [.font: bold]
            case .italic:
                attributes = [.font: italic]
            case .code:
                attributes = [
                    .font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                    .backgroundColor: UIColor.quaternarySystemFill
                ]
            case .link:
                attributes = [
                    .foregroundColor: UIColor.tintColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            case .quote:
                attributes = [
                    .font: italic,
                    .foregroundColor: UIColor.secondaryLabel
                ]
            case let .heading(level):
                let size = level == 1 ? 28.0 : level == 2 ? 23.0 : 19.0
                attributes = [
                    .font: UIFont(name: "NewYork-Bold", size: size) ??
                        .boldSystemFont(ofSize: size)
                ]
            }
            textStorage.addAttributes(attributes, range: range)
        }
        let source = text as NSString
        for passage in highlightedPassages where !passage.isEmpty {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(of: passage, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                textStorage.addAttribute(
                    .backgroundColor,
                    value: UIColor.systemYellow.withAlphaComponent(0.34),
                    range: found
                )
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }
        textStorage.endEditing()
        typingAttributes = [
            .font: body,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
        setNeedsDisplay()
    }

}
#endif
