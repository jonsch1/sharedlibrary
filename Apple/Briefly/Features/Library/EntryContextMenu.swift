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

struct EntryContextMenu: ViewModifier {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry
    @State private var confirmsTrash = false

    func body(content: Content) -> some View {
        content.contextMenu {
            if let source = entry.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label("Open original", systemImage: "arrow.up.right")
                }
            }
            if model.session.canEdit {
                Button {
                    Task {
                        await model.workflows.select(entry.id)
                        await model.workflows.processSelected()
                    }
                } label: {
                    Label("Regenerate summaries", systemImage: "sparkles")
                }
                .disabled(model.processing.isProcessing)
                Divider()
                Button(role: .destructive) {
                    confirmsTrash = true
                } label: {
                    Label(
                        model.selection.selectionCount(for: entry.id) > 1
                            ? "Move Items to Trash"
                            : "Move to Trash",
                        systemImage: "trash"
                    )
                }
            }
        }
        .confirmationDialog(
            model.selection.selectionCount(for: entry.id) > 1
                ? "Move \(model.selection.selectionCount(for: entry.id)) items to Trash?"
                : "Move this item to Trash?",
            isPresented: $confirmsTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.workflows.trash(entryID: entry.id) }
            }
        }
    }
}
