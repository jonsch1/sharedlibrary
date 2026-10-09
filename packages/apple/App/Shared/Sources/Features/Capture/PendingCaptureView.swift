import BrieflyCore
import SwiftUI

/// Pending captures show the saved input and handoff state, never an empty reader.
struct PendingCaptureView: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if os(macOS)
                Button("Back", systemImage: "arrow.left") {
                    Task { await model.workflows.select("") }
                }
                .buttonStyle(.plain)
                #endif

                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 8) {
                    Text("SAVED TO YOUR INBOX")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.title).font(.title2.bold())
                    Label(model.captureStatus(for: entry), systemImage: statusIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }

                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = model.lifecycle.syncError {
                    Label(error, systemImage: "icloud.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let request = entry.captureRequest {
                    switch request.payload {
                    case .url(let value):
                        if let url = URL(string: value) {
                            Link(destination: url) {
                                Label(value, systemImage: "link")
                                    .lineLimit(3)
                            }
                        }
                    case .text(let value):
                        Text(value).textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4))
                    case .pdf(let filename):
                        Label(filename, systemImage: "doc.richtext")
                        Text("The original PDF is saved with this item.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = request.error {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !model.navigation.showingTrash {
                    if entry.captureRequest?.state == .failed {
                        Button("Retry on Mac", systemImage: "arrow.clockwise") {
                            Task { await model.workflows.retryCapture(entry.id) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await model.workflows.sync() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.lifecycle.isSyncing)
                    }
                    Button("Remove from inbox", systemImage: "trash", role: .destructive) {
                        Task { await model.workflows.trash(entryID: entry.id) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
            .frame(maxWidth: 580, alignment: .leading)
            .frame(maxWidth: .infinity)
            #if os(macOS)
            .readingColumn()
            #endif
        }
        .accessibilityIdentifier("capture.pending")
    }

    private var statusIcon: String {
        entry.captureRequest?.state == .failed ? "exclamationmark.circle" : "desktopcomputer"
    }

    private var explanation: String {
        switch entry.captureRequest?.state {
        case .failed:
            "Your original input is safe. Resolve the issue on your Mac, then retry."
        case .extracting, .summarizing:
            "Your Mac is preparing this item. Its source and summaries will appear here after syncing."
        default:
            "Open Briefly on your Mac to prepare this item. Both devices need iCloud enabled with the same Apple Account. If your Mac is asleep or offline, this item will wait safely here."
        }
    }
}

struct PendingCaptureRow: View {
    let entry: LibraryEntry
    let status: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: entry.captureRequest?.state == .failed
                      ? "exclamationmark.circle" : "tray.and.arrow.down")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).font(.body.weight(.medium)).lineLimit(2)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.05))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("capture.pending.\(entry.id)")
    }
}
