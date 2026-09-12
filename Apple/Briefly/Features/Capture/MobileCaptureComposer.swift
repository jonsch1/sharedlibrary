import SwiftUI

#if os(iOS)
struct MobileCaptureComposer: View {
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
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: 19))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .disabled(isSaving)
                    .accessibilityIdentifier("capture.text")
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Paste a link or write something…")
                                .font(.system(size: 19))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 19)
                                .padding(.top, 22)
                                .allowsHitTesting(false)
                        }
                    }

                Divider()

                HStack(spacing: 8) {
                    composerTool("doc.richtext", label: "Import PDF", action: openPDFImporter)
                    composerTool("globe", label: "Signed-in browser", action: openBrowser)
                    Spacer()
                    if model.processing.isProcessing { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .frame(height: 58)
                .disabled(isSaving)
                if let error = model.session.errorMessage, !isSaving {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .background { BrieflyAtmosphere().ignoresSafeArea() }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
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
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task { focused = true }
    }

    private func composerTool(
        _ icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#endif
