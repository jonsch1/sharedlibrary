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

#if os(iOS)
struct EditableDocumentTextView: UIViewRepresentable {
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

final class MarkdownTextView: UITextView {
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
