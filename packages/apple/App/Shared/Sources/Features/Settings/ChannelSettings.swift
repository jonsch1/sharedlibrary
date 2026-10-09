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
            Group {
                if model.navigation.selectedChannelSource == "new" {
                    channelCreation
                } else if let channel = model.channels.selectedChannel(for: model.navigation.selectedChannelSource) {
                    channelEditor(channel)
                } else {
                    XEmptyState(
                        icon: "dot.radiowaves.left.and.right",
                        title: "No channel selected",
                        message: "Choose a channel to edit, or add a new one."
                    )
                    .frame(minHeight: 360)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        #if os(macOS)
        .fadingHeaderBar {
            HStack(spacing: 12) {
                Button {
                    model.workflows.navigateBack()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .help("Back")
                Spacer()
                Picker("Channel", selection: channelSelection) {
                    Text("New channel").tag("new")
                    ForEach(model.channels.channels) { channel in
                        Text(channel.title).tag(channel.source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
        }
        #endif
        .buttonBorderShape(.roundedRectangle(radius: 0))
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
        .confirmationDialog("Remove this channel?", isPresented: $confirmsRemoval) {
            Button("Remove channel and pending candidates", role: .destructive) {
                Task { await model.workflows.removeSelectedChannel() }
            }
        } message: {
            let count = model.channels.selectedChannel(for: model.navigation.selectedChannelSource).map {
                model.channels.reviewCandidateCount(for: $0)
            } ?? 0
            Text(
                count == 1
                    ? "The channel and its 1 pending candidate will be removed. Accepted items stay in your library."
                    : "The channel and its \(count) pending candidates will be removed. Accepted items stay in your library."
            )
        }
    }

    #if os(macOS)
    private var channelSelection: Binding<String> {
        Binding(
            get: { model.navigation.selectedChannelSource },
            set: { model.workflows.showChannelSettings($0) }
        )
    }
    #endif

    private func channelEditor(_ channel: LibraryChannel) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                channelHeading(
                    icon: channel.kind == .podcast ? "waveform" : "dot.radiowaves.left.and.right",
                    eyebrow: "Channel"
                ) {
                    TextField("Channel name", text: $channelTitle)
                        .textFieldStyle(.plain)
                        .font(.title.weight(.bold))
                        .onSubmit(saveSettings)
                        .accessibilityLabel("Channel name")
                }

                HStack(alignment: .top, spacing: 32) {
                    channelFact("Items", value: model.channels.channelEntries(for: channel.source).count.formatted())
                    channelFact("Type", value: channel.kind?.rawValue.capitalized ?? "Not checked")
                    channelFact("Last checked", value: channel.lastCheckedAt ?? "Never")
                }

                if let error = channel.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            channelSourceEditor(listTitle: "Included sources")

            SettingsGroup(
                title: "Review",
                footer: "Briefly finds candidates without saving them. Summaries start only after you accept an item."
            ) {
                SettingsRow(
                    icon: "tray.full",
                    title: "Review window",
                    subtitle: "Keep up to \(reviewWindow) candidates ready to review."
                ) {
                    HStack(spacing: 2) {
                        reviewStep("minus", label: "Fewer candidates", by: -1)
                        reviewStep("plus", label: "More candidates", by: 1)
                    }
                }
            }

            HStack {
                Text(sourceCountLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save changes", action: saveSettings)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.channels.newChannelSources.isEmpty ||
                            channelTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }

            SettingsGroup(title: "Actions") {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsActionRow(
                        icon: "arrow.clockwise",
                        title: model.supportsAIProcessing ? "Check for new items" : "Sync candidates",
                        isWorking: model.channels.isCheckingChannel
                    ) {
                        Task { await model.workflows.checkSelectedChannel() }
                    }
                    .disabled(model.channels.isCheckingChannel)
                    SettingsActionRow(icon: "trash", title: "Remove channel…", role: .destructive) {
                        confirmsRemoval = true
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, bottomPadding)
    }

    private var channelCreation: some View {
        VStack(alignment: .leading, spacing: 32) {
            channelHeading(icon: "dot.radiowaves.left.and.right", eyebrow: "New channel") {
                Text("Create a channel")
                    .font(.title.weight(.bold))
                Text("Collect updates from the sites and people you follow in one place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            channelSourceEditor(
                listTitle: "Added sources",
                hint: "Start with a website, newsletter, podcast, profile, or any public page."
            )

            HStack(spacing: 12) {
                if !model.channels.newChannelSources.isEmpty {
                    Text(sourceCountLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Create channel") {
                    Task { await model.workflows.createChannel() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.channels.newChannelSources.isEmpty)
                .accessibilityIdentifier("channels.create")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, bottomPadding)
    }

    private func channelHeading<Title: View>(
        icon: String,
        eyebrow: String,
        @ViewBuilder title: () -> Title
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: Rectangle())
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                title()
            }
        }
    }

    private func reviewStep(_ icon: String, label: String, by delta: Int) -> some View {
        let next = reviewWindow + delta
        return Button {
            reviewWindow = next
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 36)
                .background(Color.primary.opacity(0.055), in: Rectangle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!channelReviewLimitRange.contains(next))
        .accessibilityLabel(label)
    }

    private func channelFact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
    }

    private var sourceCountLabel: String {
        let count = model.channels.newChannelSources.count
        return count == 1 ? "1 source" : "\(count) sources"
    }

    /// Leaves room for the floating tab bar on iOS.
    private var bottomPadding: CGFloat {
        #if os(iOS)
        120
        #else
        40
        #endif
    }

    private var sourceIsEmpty: Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addSource() {
        model.channels.stageChannelSource(source)
        source = ""
    }

    private func channelSourceEditor(listTitle: String, hint: String? = nil) -> some View {
        SettingsGroup(
            title: "Sources",
            footer: model.channels.newChannelSources.isEmpty ? hint : nil
        ) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("Paste a domain or URL", text: $source)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .focused($sourceFieldFocused)
                        .onSubmit(addSource)
                        .accessibilityIdentifier("channels.source")
                }
                .settingsField()

                Button(action: addSource) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.background)
                        .frame(width: 40, height: 40)
                        .background(Color.primary, in: Rectangle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sourceIsEmpty)
                .opacity(sourceIsEmpty ? 0.3 : 1)
                .accessibilityLabel("Add source")
                .accessibilityIdentifier("channels.source.add")
            }

            if !model.channels.newChannelSources.isEmpty {
                Text(listTitle)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(model.channels.newChannelSources, id: \.self) { source in
                        ChannelSourceCard(source: source) {
                            model.channels.removeStagedChannelSource(source)
                        }
                    }
                }
            }
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
