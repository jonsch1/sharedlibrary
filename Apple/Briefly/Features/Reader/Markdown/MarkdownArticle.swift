import SwiftUI

struct MarkdownArticle: View {
    let lines: [String]

    init(_ text: String) {
        lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MarkdownLine(line: line)
            }
        }
        .textSelection(.enabled)
    }
}

struct MarkdownLine: View {
    let line: String

    var body: some View {
        if line.isEmpty {
            Color.clear.frame(height: 16)
        } else if line.hasPrefix("# ") {
            markdownText(String(line.dropFirst(2)))
                .font(.system(size: 28, weight: .bold, design: .serif))
                .lineSpacing(4)
                .padding(.bottom, 2)
        } else if line.hasPrefix("## ") {
            markdownText(String(line.dropFirst(3)))
                .font(.system(size: 23, weight: .bold, design: .serif))
                .padding(.top, 8)
        } else if line.hasPrefix("### ") {
            markdownText(String(line.dropFirst(4)))
                .font(.system(size: 19, weight: .bold, design: .serif))
                .padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                markdownText(String(line.dropFirst(2)))
            }
            .articleBodyStyle()
        } else if line.hasPrefix("> ") {
            markdownText(String(line.dropFirst(2)))
                .articleBodyStyle()
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 3)
                }
        } else {
            markdownText(line)
                .articleBodyStyle()
        }
    }

    private func markdownText(_ value: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(value)
        }
        return Text(attributed)
    }
}

private extension View {
    func articleBodyStyle() -> some View {
        font(.system(size: 19, weight: .regular, design: .serif))
            .lineSpacing(7)
            .fixedSize(horizontal: false, vertical: true)
    }
}
