import SwiftUI

#if os(iOS)
import UIKit
import BrieflyCore

/// Title and source line drawn above the reader text so they scroll with it.
struct ReaderHeading: Equatable {
    let title: String
    let byline: String

    init(entry: LibraryEntry) {
        title = entry.title
        byline = [
            entry.sourceName,
            entry.savedDate?.formatted(date: .abbreviated, time: .omitted)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

extension EnvironmentValues {
    @Entry var readerHeading: ReaderHeading? = nil
}

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
            top: MarkdownTextView.contentTop,
            left: 24,
            bottom: 160,
            right: 24
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.heading = context.environment.readerHeading
        textView.highlightedPassages = highlightedPassages
        textView.setMarkdown(text)
        return textView
    }

    func updateUIView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.heading = context.environment.readerHeading
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
    static let contentTop: CGFloat = 24
    var highlightedPassages = [String]()
    var heading: ReaderHeading? {
        didSet {
            guard heading != oldValue else { return }
            titleLabel.text = heading?.title
            bylineLabel.text = heading?.byline
            headingView.isHidden = heading == nil
            setNeedsLayout()
        }
    }
    private var isRendering = false
    private let titleLabel = UILabel()
    private let bylineLabel = UILabel()
    private lazy var headingView: UIStackView = {
        titleLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(
            for: roundedFont(size: 28, weight: .bold)
        )
        titleLabel.numberOfLines = 0
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits = .header
        bylineLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: roundedFont(size: 15, weight: .medium)
        )
        bylineLabel.numberOfLines = 1
        bylineLabel.textColor = .secondaryLabel
        for label in [titleLabel, bylineLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        let stack = UIStackView(arrangedSubviews: [titleLabel, bylineLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.isHidden = true
        addSubview(stack)
        return stack
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHeading()
    }

    /// Places the heading in the top text inset and grows the inset to fit it.
    private func layoutHeading() {
        var top = Self.contentTop
        if heading != nil {
            let width = bounds.width - textContainerInset.left - textContainerInset.right
            let height = headingView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            headingView.frame = CGRect(
                x: textContainerInset.left,
                y: Self.contentTop,
                width: width,
                height: height
            )
            top += height + 28
        }
        if textContainerInset.top != top {
            textContainerInset.top = top
        }
    }

    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }

    func setMarkdown(_ markdown: String) {
        text = markdown
        renderMarkdown()
    }

    func renderMarkdown() {
        guard !isRendering else { return }
        let previousContentOffset = contentOffset
        isRendering = true
        defer {
            isRendering = false
            restoreContentOffset(previousContentOffset)
        }
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
        applyMarkdownStyling(
            to: textStorage,
            text: text,
            highlightedPassages: highlightedPassages,
            baseAttributes: [
                .font: body,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ],
            attributesFor: { style in
                switch style {
                case .hidden:
                    return [.font: hidden, .foregroundColor: UIColor.clear]
                case .bold:
                    return [.font: bold]
                case .italic:
                    return [.font: italic]
                case .code:
                    return [
                        .font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                        .backgroundColor: UIColor.quaternarySystemFill
                    ]
                case .link:
                    return [
                        .foregroundColor: UIColor.tintColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                case .quote:
                    return [
                        .font: italic,
                        .foregroundColor: UIColor.secondaryLabel
                    ]
                case let .heading(level):
                    let size = level == 1 ? 28.0 : level == 2 ? 23.0 : 19.0
                    return [
                        .font: UIFont(name: "NewYork-Bold", size: size) ??
                            .boldSystemFont(ofSize: size)
                    ]
                }
            },
            highlightAttributes: [
                .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.34)
            ]
        )
        textStorage.endEditing()
        typingAttributes = [
            .font: body,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
        setNeedsDisplay()
    }

    private func restoreContentOffset(_ offset: CGPoint) {
        guard bounds.height > 0 else { return }
        layoutIfNeeded()

        let minimumX = -adjustedContentInset.left
        let maximumX = max(
            minimumX,
            contentSize.width - bounds.width + adjustedContentInset.right
        )
        let minimumY = -adjustedContentInset.top
        let maximumY = max(
            minimumY,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )

        contentOffset = CGPoint(
            x: min(max(offset.x, minimumX), maximumX),
            y: min(max(offset.y, minimumY), maximumY)
        )
    }

}
#endif
