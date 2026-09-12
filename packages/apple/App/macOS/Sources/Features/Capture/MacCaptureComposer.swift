import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct MacCaptureComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let openPDFImporter: () -> Void
    let openBrowser: () -> Void
    @State private var draft = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var canCapture: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.processing.isProcessing && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                Text("Capture")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    let value = draft
                    isSaving = true
                    model.workflows.clearError()
                    Task {
                        await model.workflows.capture(value, onCaptured: { dismiss() })
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 0))
                .disabled(!canCapture)
                .accessibilityIdentifier("capture.save")
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        Image(systemName: "doc.text")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 42, height: 42)

                TextEditor(text: $draft)
                    .font(.system(size: 18))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .disabled(isSaving)
                    .accessibilityIdentifier("capture.text")
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Paste a link or write something…")
                                .font(.system(size: 18))
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                    }
            }
            .padding(16)
            .frame(minHeight: 190, alignment: .top)

            if let error = model.session.errorMessage, !isSaving {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack(spacing: 4) {
                composerTool("doc.richtext", label: "Import PDF", action: openPDFImporter)
                composerTool("globe", label: "Signed-in browser", action: openBrowser)
                composerTool("clipboard", label: "Paste clipboard") {
                    draft = NSPasteboard.general.string(forType: .string) ?? ""
                }
                Spacer()
                if model.processing.isProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .disabled(isSaving)
        }
        .frame(width: 600)
        .frame(minHeight: 302)
        .background(.regularMaterial)
        .interactiveDismissDisabled(isSaving)
        .task {
            if draft.isEmpty {
                draft = NSPasteboard.general.string(forType: .string) ?? ""
            }
            focused = true
        }
    }

    private func composerTool(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

#endif
