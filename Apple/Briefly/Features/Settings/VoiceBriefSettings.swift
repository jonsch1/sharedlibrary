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

struct VoiceBriefConfiguration: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    @State private var title = ""
    @State private var schedule = "manual"
    @State private var sources = ""
    @State private var prioritizeForMe = false
    @State private var confirmsTrash = false

    private var selectedSources: Set<String> {
        Set(
            sources.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            if model.canEdit &&
                (model.selectedVoiceBrief != nil || model.selectedVoiceBriefID == "new")
            {
                VStack(alignment: .leading, spacing: 28) {
                    TextField("Voice brief title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .bold))

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Channels")
                                    .font(.headline)
                                Text("Choose from your configured Channel library.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(model.channels.count(where: isChannelSelected)) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.channels.isEmpty {
                            Label(
                                "Add channels in the Channel tab, then choose them here.",
                                systemImage: "dot.radiowaves.left.and.right"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 86)
                            .background(.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        .primary.opacity(0.14),
                                        style: StrokeStyle(dash: [4])
                                    )
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(model.channels) { channel in
                                    Button {
                                        toggleChannel(channel)
                                    } label: {
                                        HStack(spacing: 11) {
                                            Image(
                                                systemName: isChannelSelected(channel)
                                                    ? "checkmark.circle.fill"
                                                    : "circle"
                                            )
                                            .foregroundStyle(
                                                isChannelSelected(channel)
                                                    ? Color.accentColor
                                                    : Color.secondary
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(channel.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                Text(channel.sources.joined(separator: " · "))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 12)
                                            Text("\(channel.items.count)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 52)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(
                                        isChannelSelected(channel)
                                            ? Color.accentColor.opacity(0.1)
                                            : Color.clear
                                    )

                                    if channel.id != model.channels.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.primary.opacity(0.14))
                            }
                        }
                    }

                    ScheduleEditor(schedule: $schedule)

                    HStack {
                        if model.selectedVoiceBrief != nil {
                            Button("Move voice brief to Trash", role: .destructive) {
                                confirmsTrash = true
                            }
                        }
                        Spacer()
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.64))
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
            } else if let brief = model.selectedVoiceBrief {
                ConfigurationCard(
                    eyebrow: "VOICE BRIEF",
                    title: brief.title,
                    description: "A private brief assembled from the selected channel summaries."
                ) {
                    LabeledContent("Schedule", value: brief.schedule)
                    LabeledContent("Sources", value: brief.sources.joined(separator: "\n"))
                }
            } else {
                XEmptyState(
                    icon: "headphones",
                    title: "No voice briefs",
                    message: "Create a voice brief to gather and synthesize channels."
                )
                .frame(maxWidth: 680)
                .background(.ultraThinMaterial.opacity(0.64))
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.canEdit &&
                (model.selectedVoiceBrief != nil || model.selectedVoiceBriefID == "new")
            {
                HStack(spacing: 10) {
                    Button {
                        model.navigateBack()
                        #if os(iOS)
                        dismiss()
                        #endif
                    } label: {
                        Image(systemName: "arrow.left")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("Voice brief")
                        .font(.headline)
                    Spacer(minLength: 0)

                    Button {
                        Task { await save() }
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(!canSave)
                }
                .padding(.horizontal, 18)
                .frame(height: 56)
                .frame(maxWidth: 680)
                .background(.regularMaterial)
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .task(id: model.selectedVoiceBriefID) {
            loadDraft()
        }
        .confirmationDialog(
            "Move this voice brief to Trash?",
            isPresented: $confirmsTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashSelectedVoiceBrief() }
            }
        }
    }

    private func save() async {
        let saved = await model.saveVoiceBrief(
            LibraryVoiceBriefDraft(
                id: model.selectedVoiceBrief?.id,
                title: title,
                schedule: schedule,
                length: "",
                sources: Array(selectedSources),
                prioritizeForMe: prioritizeForMe
            )
        )
        guard saved != nil else { return }
        model.showingVoiceBriefSettings = false
        #if os(iOS)
        dismiss()
        #endif
    }

    private func isChannelSelected(_ channel: LibraryChannel) -> Bool {
        !channel.sources.isEmpty && channel.sources.allSatisfy(selectedSources.contains)
    }

    private func toggleChannel(_ channel: LibraryChannel) {
        var selected = selectedSources
        if isChannelSelected(channel) {
            selected.subtract(channel.sources)
        } else {
            selected.formUnion(channel.sources)
        }
        sources = selected.sorted().joined(separator: "\n")
    }

    private func loadDraft() {
        if let brief = model.selectedVoiceBrief {
            title = brief.title
            schedule = brief.schedule
            sources = brief.sources.joined(separator: "\n")
            prioritizeForMe = brief.prioritizeForMe == true
        } else {
            title = "New voice brief"
            schedule = "manual"
            sources = ""
            prioritizeForMe = false
        }
    }
}
