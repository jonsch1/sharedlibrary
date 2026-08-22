import Foundation
import SwiftUI
import BrieflyCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ShareDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var link: BrieflyShareLinkStatus?
    @State private var isBusy = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Share")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("PUBLIC READER", systemImage: "link")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)

                    Text(entry.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(3)

                    Text(
                        "Share the summaries and a listenable audio version. Your private captured source stays private."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.72))
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .stroke(Color.primary.opacity(0.10))
                }

                if !model.account.account.authenticated {
                    Label(
                        "Sign in to your Briefly account in Settings before publishing.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else if let urlString = link?.url, let url = URL(string: urlString) {
                    Text(url.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.055), in: Rectangle())
                    HStack {
                        Button("Copy link", systemImage: "doc.on.doc") {
                            copyShareURL(url)
                            model.session.status = "Share link copied"
                        }
                        ShareLink(item: url) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button("Stop sharing", role: .destructive) {
                            Task { await revoke() }
                        }
                    }
                } else if link?.shared == true {
                    Label("Publishing continues in the background.", systemImage: "clock")
                } else {
                    Button {
                        Task { await publish() }
                    } label: {
                        HStack {
                            if isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "link.badge.plus")
                            }
                            Text(isBusy ? "Creating link…" : "Create link & copy")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 0))
                    .disabled(isBusy)

                    Label(
                        "The link is copied as soon as it exists. Publishing finishes in the background.",
                        systemImage: "bolt.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.regularMaterial)
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 390)
        #endif
    }

    private func load() async {
        guard model.account.account.authenticated else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            link = try await model.sharing.shareStatus(for: entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publish() async {
        isBusy = true
        errorMessage = ""
        defer { isBusy = false }
        do {
            link = try await model.sharing.publishShare(for: entry)
            if let value = link?.url, let url = URL(string: value) {
                copyShareURL(url)
                model.session.status = "Share link copied. Publishing in the background…"
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke() async {
        guard let token = link?.token else { return }
        isBusy = true
        errorMessage = ""
        defer { isBusy = false }
        do {
            try await model.sharing.revokeShare(token)
            link = BrieflyShareLinkStatus(
                shared: false,
                token: nil,
                url: nil,
                status: nil,
                error: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyShareURL(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
    }
}
