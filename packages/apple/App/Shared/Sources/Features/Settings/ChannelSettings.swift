import BrieflyCore
import Foundation
import SwiftUI

struct ChannelConfiguration: View {
    @Bindable var model: LibraryModel
    @State private var source = ""
    @State private var channelTitle = ""
    @State private var reviewWindow = defaultChannelReviewLimit
    @State private var confirmsRemoval = false
    @FocusState private var sourceFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                #if !os(macOS)
                channelPicker
                #endif

                if model.navigation.selectedChannelSource == "new" {
                    channelCreation
                } else if let channel = model.channels.selectedChannel(for: model.navigation.selectedChannelSource) {
                #if os(macOS)
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(
                            systemName: channel.kind == .podcast
                                ? "waveform"
                                : "dot.radiowaves.left.and.right"
                        )
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58, height: 58)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Rectangle())

                        VStack(alignment: .leading, spacing: 6) {
                            Text("CHANNEL")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Channel name", text: $channelTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 28, weight: .bold))
                                .onSubmit(saveSettings)
                        }

                        Spacer(minLength: 20)

                        Button {
                            Task { await model.workflows.checkSelectedChannel() }
                        } label: {
                            if model.channels.isCheckingChannel {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(model.supportsAIProcessing ? "Fetch fresh" : "Sync candidates", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.channels.isCheckingChannel)

                        Menu {
                            Button("Remove channel", role: .destructive) {
                                confirmsRemoval = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("More channel actions")
                    }

                    Divider()

                    channelSourceEditor(listTitle: "Included sources")

                    Grid(alignment: .leading, horizontalSpacing: 52, verticalSpacing: 6) {
                        GridRow {
                            Text("CAPTURED ITEMS")
                            Text("TYPE")
                            Text("LAST CHECKED")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        GridRow {
                            Text(model.channels.channelEntries(for: channel.source).count.formatted())
                            Text(channel.kind?.rawValue.capitalized ?? "Not checked")
                            Text(channel.lastCheckedAt ?? "Never")
                        }
                        .font(.title3.weight(.semibold))
                    }

                    if let error = channel.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.08), in: Rectangle())
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review window")
                                .font(.headline)
                            Text("How many pending candidates Briefly keeps available to review.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(
                            "Candidates: \(reviewWindow)",
                            value: $reviewWindow,
                            in: channelReviewLimitRange
                        )
                        .fixedSize()
                    }
                    Text("Briefly discovers candidates without saving them. Summaries start only after you accept an item.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()
                    HStack {
                        Text("\(model.channels.newChannelSources.count) " +
                             (model.channels.newChannelSources.count == 1 ? "source" : "sources"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save changes", action: saveSettings)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(
                                model.channels.newChannelSources.isEmpty ||
                                    channelTitle.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .background(
                    .thinMaterial,
                    in: Rectangle()
                )
                .overlay {
                    Rectangle()
                        .stroke(Color.primary.opacity(0.10))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .top)
                #else
                ConfigurationCard(
                    eyebrow: "CHANNEL",
                    title: "Channel settings",
                    description: "Edit this channel's name, sources, and review settings."
                ) {
                    TextField("Channel name", text: $channelTitle)
                        .font(.system(size: 28, weight: .bold))
                        .onSubmit(saveSettings)
                    LabeledContent(
                        "Captured items",
                        value: model.channels.channelEntries(for: channel.source).count.formatted()
                    )
                    LabeledContent(
                        "Type",
                        value: channel.kind?.rawValue.capitalized ?? "Not checked"
                    )
                    LabeledContent(
                        "Last checked",
                        value: channel.lastCheckedAt ?? "Never"
                    )
                    if let error = channel.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    channelSourceEditor(listTitle: "Included sources")
                    Text("Review window")
                        .font(.headline)
                    Stepper(
                        "Candidates: \(reviewWindow)",
                        value: $reviewWindow,
                        in: channelReviewLimitRange
                    )
                    Text("Briefly discovers candidates without saving them. Summaries start only after you accept an item.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task { await model.workflows.checkSelectedChannel() }
                        } label: {
                            if model.channels.isCheckingChannel {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(model.supportsAIProcessing ? "Fetch fresh" : "Sync candidates", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.channels.isCheckingChannel)
                    }
                    HStack {
                        Text("\(model.channels.newChannelSources.count) " +
                             (model.channels.newChannelSources.count == 1 ? "source" : "sources"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save changes", action: saveSettings)
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.channels.newChannelSources.isEmpty ||
                                    channelTitle.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                    }
                    Divider()
                    Button("Remove channel", role: .destructive) {
                        confirmsRemoval = true
                    }
                }
                #endif
                } else {
                    XEmptyState(
                        icon: "dot.radiowaves.left.and.right",
                        title: "No channels",
                        message: "Add a channel to gather new material."
                    )
                    .frame(maxWidth: 680)
                    .background(.ultraThinMaterial.opacity(0.64))
                    .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    model.workflows.navigateBack()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Manage Channels")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("Channel", selection: channelSelection) {
                    Text("Add a channel").tag("new")
                    ForEach(model.channels.channels) { channel in
                        Text(channel.title).tag(channel.source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
        #endif
        .task(id: model.navigation.selectedChannelSource) {
            source = ""
            let selectedChannel = model.channels.selectedChannel(for: model.navigation.selectedChannelSource)
            reviewWindow = min(
                channelReviewLimitRange.upperBound,
                max(channelReviewLimitRange.lowerBound, selectedChannel?.reviewLimit ?? defaultChannelReviewLimit)
            )
            channelTitle = selectedChannel?.title ?? ""
            model.channels.newChannelSources = model.navigation.selectedChannelSource == "new"
                ? []
                : selectedChannel?.sources ?? []
            sourceFieldFocused = model.navigation.selectedChannelSource == "new"
        }
        .confirmationDialog("Delete this channel?", isPresented: $confirmsRemoval) {
            Button("Remove channel and pending candidates", role: .destructive) {
                Task { await model.workflows.removeSelectedChannel() }
            }
        } message: {
            let count = model.channels.selectedChannel(for: model.navigation.selectedChannelSource).map {
                model.channels.reviewCandidateCount(for: $0)
            } ?? 0
            Text(
                count == 1
                    ? "The channel and its 1 pending candidate will be removed. Accepted documents stay in your library."
                    : "The channel and its \(count) pending candidates will be removed. Accepted documents stay in your library."
            )
        }
    }

    private var channelPicker: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Channel")
                    .font(.headline)
                Text("Add a channel or choose one to update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Channel", selection: channelSelection) {
                Text("Add a channel").tag("new")
                ForEach(model.channels.channels) { channel in
                    Text(channel.title).tag(channel.source)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(20)
        .frame(maxWidth: 680)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var channelSelection: Binding<String> {
        Binding(
            get: { model.navigation.selectedChannelSource },
            set: { model.workflows.showChannelSettings($0) }
        )
    }

    private var channelCreation: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: Rectangle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("Create a channel")
                        .font(.system(size: 26, weight: .bold))
                    Text("Collect updates from the sites and people you follow in one place.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                channelSourceEditor(listTitle: "Added sources")

                if model.channels.newChannelSources.isEmpty {
                    Label(
                        "Start with a website, newsletter, podcast, profile, or any public page.",
                        systemImage: "sparkles"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Divider()

            HStack(spacing: 12) {
                Text(stagedSourceCountLabel)
                    .font(.callout)
                    .foregroundStyle(model.channels.newChannelSources.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Cancel") {
                    model.channels.newChannelSources = []
                    model.workflows.navigateBack()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Create channel") {
                    Task { await model.workflows.createChannel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.channels.newChannelSources.isEmpty)
                .accessibilityIdentifier("channels.create")
            }
            .padding(20)
        }
        .frame(maxWidth: 560, alignment: .topLeading)
        .background(
            .thinMaterial,
            in: Rectangle()
        )
        .overlay {
            Rectangle()
                .stroke(Color.primary.opacity(0.10))
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, alignment: .top)
        #else
        ConfigurationCard(
            eyebrow: "CHANNEL",
            title: "Add channel",
            description: "Add websites, blogs, podcasts, profiles, or pages to this channel."
        ) {
            channelSourceEditor(listTitle: "Added sources")
            HStack {
                Text(stagedSourceCountLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.channels.newChannelSources = []
                    model.workflows.navigateBack()
                }
                Button("Create channel") {
                    Task { await model.workflows.createChannel() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.channels.newChannelSources.isEmpty)
                .accessibilityIdentifier("channels.create")
            }
        }
        #endif
    }

    private var stagedSourceCountLabel: String {
        let count = model.channels.newChannelSources.count
        return count == 1 ? "1 source added" : "\(count) sources added"
    }

    private func addSource() {
        model.channels.stageChannelSource(source)
        source = ""
    }

    @ViewBuilder
    private func channelSourceEditor(
        listTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sources")
                .font(.headline)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("Paste a domain or URL", text: $source)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($sourceFieldFocused)
                        .onSubmit(addSource)
                        .accessibilityIdentifier("channels.source")

                    Button(action: addSource) {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("channels.source.add")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 58)

            }
            .background(.primary.opacity(0.035), in: Rectangle())
            .overlay {
                Rectangle()
                    .stroke(.primary.opacity(0.12), lineWidth: 1)
            }
        }

        if !model.channels.newChannelSources.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(listTitle)
                        .font(.headline)
                    Spacer()
                    Text(model.channels.newChannelSources.count.formatted())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.07), in: Rectangle())
                }
                ForEach(model.channels.newChannelSources, id: \.self) { source in
                    ChannelSourceCard(
                        source: source,
                        remove: {
                            model.channels.removeStagedChannelSource(source)
                        }
                    )
                }
            }
            .padding(.top, 24)
        }
    }

    private func saveSettings() {
        Task {
            await model.workflows.updateSelectedChannel(
                title: channelTitle,
                sources: model.channels.newChannelSources,
                reviewWindow: reviewWindow
            )
        }
    }
}
