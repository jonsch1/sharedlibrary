import BrieflyCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LibraryExportControls: View {
    @Bindable var model: LibraryModel
    @State private var isExporting = false
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var showsExporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export everything stored on this device, including summaries, sources, attachments, and pending items. Sync first to include changes from other devices.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Export SQLite database…") { begin(.sqlite) }
            Button("Export Markdown folder…") { begin(.markdown) }
            if isExporting { ProgressView("Preparing export…").controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .disabled(isExporting || model.session.library == nil)
        #if os(iOS)
        .sheet(isPresented: $showsExporter, onDismiss: cleanUp) {
            if let exportURL {
                LibraryExportPicker(url: exportURL) { saved in
                    message = saved ? "Library exported." : nil
                    showsExporter = false
                }
            }
        }
        #endif
    }

    private func begin(_ format: LibraryExportFormat) {
        guard let library = model.session.library else { return }
        message = nil
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Export library"
        panel.message = "Choose where to save \(format.filename)."
        panel.prompt = "Export here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let access = folder.startAccessingSecurityScopedResource()
            isExporting = true
            Task {
                defer {
                    if access { folder.stopAccessingSecurityScopedResource() }
                    isExporting = false
                }
                do {
                    try await library.exportLibrary(as: format, to: folder.appending(path: format.filename))
                    message = "Saved \(format.filename) in \(folder.lastPathComponent)."
                } catch { message = error.localizedDescription }
            }
        }
        #else
        isExporting = true
        Task {
            defer { isExporting = false }
            let root = FileManager.default.temporaryDirectory.appending(path: "briefly-share-export-\(UUID())")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appending(path: format.filename)
                try await library.exportLibrary(as: format, to: destination)
                exportURL = destination
                showsExporter = true
            } catch {
                try? FileManager.default.removeItem(at: root)
                message = error.localizedDescription
            }
        }
        #endif
    }

    private func cleanUp() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
        exportURL = nil
    }
}

#if os(iOS)
private struct LibraryExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(!urls.isEmpty)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish(false) }
    }
}
#endif
