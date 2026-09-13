#if os(macOS)
import Foundation

func ingestText(_ request: ItemInputRequest) throws -> ItemDraft {
    guard case .text(let value) = request.source else { throw NativeInputError.unsupportedInput }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw NativeInputError.emptyInput }
    return ItemDraft(
        inputID: .text,
        title: nativeFirstUsefulLine(text),
        content: text
    )
}

#endif
