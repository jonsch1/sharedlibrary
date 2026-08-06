import BrieflyCore
import Foundation
import SwiftUI

struct ChannelConfiguration: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @State private var source = ""
    @State private var channelTitle = ""
    @State private var reviewWindow = defaultChannelReviewLimit
    @State private var schedule = "manual"
    @State private var confirmsRemoval = false

    var body: some View {
        ScrollView {
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
                        .clipShape(RoundedRectangle(cornerRadius: 14))

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
                                Label("Fetch fresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.channels.isCheckingChannel)

                        Menu {
                            Button {
                                model.channels.channelBrowserAddress = channel.primarySource
                                model.channels.channelBrowserStagesSource = false
                                showsChannelBrowser = true
                            } label: {
                                Label("Sign in", systemImage: "person.crop.circle")
                            }
                            Divider()
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

                    channelSourceEditor(listTitle: "Included sources", allowsOpening: true)

                    channelReviewReader(for: channel)

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
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    ScheduleEditor(schedule: $schedule)

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
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
                .background(.ultraThinMaterial.opacity(0.64))
                .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
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
                    channelSourceEditor(listTitle: "Included sources", allowsOpening: true)
                    channelReviewReader(for: channel)
                    ScheduleEditor(schedule: $schedule)
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
                                Label("Fetch fresh", systemImage: "arrow.clockwise")
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
                Text(model.navigation.selectedChannelSource == "new" ? "Add channel" : "Channel")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .frame(maxWidth: 680)
            .background(.regularMaterial)
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        #endif
        .task(id: model.navigation.selectedChannelSource) {
            source = ""
            let selectedChannel = model.channels.selectedChannel(for: model.navigation.selectedChannelSource)
            reviewWindow = min(
                channelReviewLimitRange.upperBound,
                max(channelReviewLimitRange.lowerBound, selectedChannel?.reviewLimit ?? defaultChannelReviewLimit)
            )
            schedule = selectedChannel?.schedule ?? "manual"
            channelTitle = selectedChannel?.title ?? ""
            model.channels.newChannelSources = model.navigation.selectedChannelSource == "new"
                ? []
                : selectedChannel?.sources ?? []
            model.channels.channelBrowserAddress = ""
            model.channels.channelBrowserStagesSource = model.navigation.selectedChannelSource == "new"
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

    private var channelCreation: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CHANNEL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Text("Add channel")
                    .font(.system(size: 32, weight: .bold))
                Text("Add websites, blogs, podcasts, profiles, or pages to this channel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 26)

            channelSourceEditor(listTitle: "Added sources", allowsOpening: false)

            Spacer(minLength: 38)
            Divider()
            HStack {
                Text("\(model.channels.newChannelSources.count) " +
                     (model.channels.newChannelSources.count == 1 ? "source" : "sources") + " added")
                    .foregroundStyle(.secondary)
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
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: 920, minHeight: 620, alignment: .topLeading)
        .padding(28)
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.58))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #endif
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func addSource() {
        model.channels.stageChannelSource(source)
        source = ""
    }

    private func channelReviewReader(for channel: LibraryChannel) -> some View {
        ChannelReviewReader(
            model: model.channels,
            channelID: channel.source,
            fallbackChannel: channel,
            requestSummary: { entryIDs in
                await model.workflows.finishAcceptedChannelItems(entryIDs)
            }
        )
    }

    @ViewBuilder
    private func channelSourceEditor(
        listTitle: String,
        allowsOpening: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sources")
                .font(.headline)
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a domain or URL", text: $source)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit(addSource)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(0.16), lineWidth: 1)
            }
            Text("Add by domain or URL, or choose a page in the browser.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Spacer()
                Button {
                    model.channels.channelBrowserAddress = ""
                    model.channels.channelBrowserStagesSource = true
                    showsChannelBrowser = true
                } label: {
                    Label("Open signed-in browser", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: addSource) {
                    Label("Add source", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }

        if !model.channels.newChannelSources.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(listTitle)
                    .font(.headline)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(model.channels.newChannelSources, id: \.self) { source in
                        ChannelSourceCard(
                            source: source,
                            openInBrowser: allowsOpening ? {
                                model.channels.channelBrowserAddress = source
                                model.channels.channelBrowserStagesSource = false
                                showsChannelBrowser = true
                            } : nil,
                            remove: {
                                model.channels.removeStagedChannelSource(source)
                            }
                        )
                    }
                }
            }
            .padding(.top, 38)
        }
    }

    private func saveSettings() {
        Task {
            await model.workflows.updateSelectedChannel(
                title: channelTitle,
                sources: model.channels.newChannelSources,
                reviewWindow: reviewWindow,
                schedule: schedule
            )
        }
    }
}
