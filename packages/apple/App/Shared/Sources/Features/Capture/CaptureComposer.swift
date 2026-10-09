import BrieflyCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CaptureComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    @State private var tab = CaptureTab.text
    @State private var draft = ""
    @State private var file: URL?
    @State private var showsFilePicker = false
    @State private var isSaving = false
    @State private var isDropTarget = false
    @FocusState private var focused: Bool

    static var fileTypes: [UTType] {
        [.pdf, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }

    private enum CaptureTab: String, CaseIterable, Identifiable {
        case text = "Text or link"
        case files = "Files"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
                Spacer()
                Text("Add to Briefly").font(.headline)
                Spacer()
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || (tab == .files ? file == nil : draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("capture.save")
            }
            #if os(iOS)
            HStack(spacing: 4) {
                ForEach(CaptureTab.allCases) { item in
                    ChoiceChip(title: item.rawValue, isSelected: tab == item, fillsWidth: true) {
                        tab = item
                    }
                }
            }
            .disabled(isSaving)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.tabs")
            #else
            Picker("Input", selection: $tab) {
                ForEach(CaptureTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .disabled(isSaving)
            .accessibilityIdentifier("capture.tabs")
            #endif

            if tab == .files {
                VStack(spacing: 18) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(file?.lastPathComponent ?? "Drop a PDF or text file here")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("PDF, plain text (.txt), or Markdown (.md)")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(file == nil ? "Choose file…" : "Choose a different file…") {
                        showsFilePicker = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("capture.choose-file")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isDropTarget ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard !isSaving, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
                    file = url
                    return true
                } isTargeted: { isDropTarget = $0 }
                .disabled(isSaving)
                .accessibilityIdentifier("capture.files")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $draft)
                        .font(.body)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(alignment: .topLeading) {
                            if draft.isEmpty {
                                // Aligns with the editor's first line inside its text inset.
                                Text("Paste a link or type a note")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13)
                                    #if os(iOS)
                                    .padding(.vertical, 16)
                                    #else
                                    .padding(.vertical, 8)
                                    #endif
                                    .accessibilityHidden(true)
                            }
                        }
                        .background(Color.primary.opacity(0.03))
                        .accessibilityIdentifier("capture.text")
                        .accessibilityLabel("Text or link")
                    Button("Paste clipboard", systemImage: "clipboard") { readClipboard() }
                        .buttonStyle(.plain)
                        .font(.callout)
                }
                .disabled(isSaving)
            }
            if let error = model.session.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(24)
        .background(.background)
        #if os(macOS)
        .frame(width: 600, height: 460)
        #endif
        .interactiveDismissDisabled(isSaving)
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: Self.fileTypes) { result in
            switch result {
            case .success(let url): file = url
            case .failure(let error): model.session.errorMessage = error.localizedDescription
            }
        }
        .task {
            model.workflows.clearError()
            readClipboard()
            // Focus only takes once the sheet has finished presenting.
            try? await Task.sleep(for: .milliseconds(400))
            focused = tab == .text
        }
    }

    private func readClipboard() {
        #if os(macOS)
        draft = NSPasteboard.general.string(forType: .string) ?? ""
        #else
        draft = UIPasteboard.general.string ?? ""
        #endif
    }

    private func save() {
        isSaving = true
        model.workflows.clearError()
        Task {
            if tab == .files, let file {
                await model.workflows.captureFile(file, onCaptured: { dismiss() })
            } else {
                await model.workflows.capture(draft, onCaptured: { dismiss() })
            }
            isSaving = false
        }
    }
}
