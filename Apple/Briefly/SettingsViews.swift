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
private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.headline)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }
}

private enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

private struct ScheduleEditor: View {
    @Binding var schedule: String

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { schedule != "manual" },
            set: { enabled in
                schedule = enabled
                    ? scheduledValue(frequency: .daily, weekday: weekday, time: time)
                    : "manual"
            }
        )
    }

    private var frequency: ScheduleFrequency {
        schedule.hasPrefix("weekly ") ? .weekly : .daily
    }

    private var frequencyBinding: Binding<ScheduleFrequency> {
        Binding(
            get: { frequency },
            set: { schedule = scheduledValue(frequency: $0, weekday: weekday, time: time) }
        )
    }

    private var weekday: Int {
        guard schedule.hasPrefix("weekly ") else {
            return Calendar.current.component(.weekday, from: Date())
        }
        let code = schedule.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            .firstIndex(of: code).map { $0 + 1 } ?? Calendar.current.firstWeekday
    }

    private var weekdayBinding: Binding<Int> {
        Binding(
            get: { weekday },
            set: { schedule = scheduledValue(frequency: frequency, weekday: $0, time: time) }
        )
    }

    private var time: Date {
        let parts = schedule.split(separator: " ").last?
            .split(separator: ":").compactMap { Int($0) } ?? []
        guard parts.count == 2 else { return Date() }
        return Calendar.current.date(
            bySettingHour: parts[0],
            minute: parts[1],
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { time },
            set: { schedule = scheduledValue(frequency: frequency, weekday: weekday, time: $0) }
        )
    }

    private var orderedWeekdays: [Int] {
        (0..<7).map { (($0 + Calendar.current.firstWeekday - 1) % 7) + 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schedule automatically")
                        .font(.headline)
                    Text("Leave this off to refresh only when you ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if isEnabled.wrappedValue {
                Picker("Frequency", selection: frequencyBinding) {
                    ForEach(ScheduleFrequency.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                if frequency == .weekly {
                    Picker("Weekday", selection: weekdayBinding) {
                        ForEach(orderedWeekdays, id: \.self) {
                            Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0)
                        }
                    }
                }
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
            }
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func scheduledValue(
        frequency: ScheduleFrequency,
        weekday: Int,
        time: Date
    ) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let value = String(format: "%02d:%02d", components.hour ?? 9, components.minute ?? 0)
        guard frequency == .weekly else { return "daily \(value)" }
        let code = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][
            min(7, max(1, weekday)) - 1
        ]
        return "weekly \(code) \(value)"
    }
}

struct ChannelConfiguration: View {
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @State private var source = ""
    @State private var channelTitle = ""
    @State private var retrievalCount = 5
    @State private var autoSummarize = true
    @State private var schedule = "manual"
    @State private var confirmsRemoval = false

    var body: some View {
        ScrollView {
            if model.selectedChannelSource == "new" {
                channelCreation
            } else if let channel = model.selectedChannel {
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
                            Task { await model.checkSelectedChannel() }
                        } label: {
                            if model.isCheckingChannel {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Fetch fresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isCheckingChannel)

                        Menu {
                            Button {
                                Task { await model.checkSelectedChannel(loadMore: true) }
                            } label: {
                                Label("Load more", systemImage: "arrow.down")
                            }
                            .disabled(model.isCheckingChannel || !channel.canLoadMore)
                            Button {
                                model.channelBrowserAddress = channel.primarySource
                                model.channelBrowserStagesSource = false
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

                    Grid(alignment: .leading, horizontalSpacing: 52, verticalSpacing: 6) {
                        GridRow {
                            Text("CAPTURED ITEMS")
                            Text("TYPE")
                            Text("LAST CHECKED")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        GridRow {
                            Text(model.channelEntries(for: channel.source).count.formatted())
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

                    Toggle("Summarize new items automatically", isOn: $autoSummarize)
                    Text("Off by default. You can summarize any captured item on demand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Refresh depth")
                                .font(.headline)
                            Text("How many recent items Briefly gathers on each check.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(
                            "Items per check: \(retrievalCount)",
                            value: $retrievalCount,
                            in: 1...100
                        )
                        .fixedSize()
                    }

                    if !channel.briefTitles.isEmpty {
                        LabeledContent(
                            "Voice briefs",
                            value: channel.briefTitles.joined(separator: ", ")
                        )
                    }

                    Divider()
                    HStack {
                        Text("\(model.newChannelSources.count) " +
                             (model.newChannelSources.count == 1 ? "source" : "sources"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save changes", action: saveSettings)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(
                                model.newChannelSources.isEmpty ||
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
                    description: "Edit this channel's name, sources, and refresh settings."
                ) {
                    TextField("Channel name", text: $channelTitle)
                        .font(.system(size: 28, weight: .bold))
                        .onSubmit(saveSettings)
                    LabeledContent(
                        "Captured items",
                        value: model.channelEntries(for: channel.source).count.formatted()
                    )
                    LabeledContent(
                        "Type",
                        value: channel.kind?.rawValue.capitalized ?? "Not checked"
                    )
                    LabeledContent(
                        "Last checked",
                        value: channel.lastCheckedAt ?? "Never"
                    )
                    if !channel.briefTitles.isEmpty {
                        LabeledContent(
                            "Voice briefs",
                            value: channel.briefTitles.joined(separator: ", ")
                        )
                    }
                    if let error = channel.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    channelSourceEditor(listTitle: "Included sources", allowsOpening: true)
                    ScheduleEditor(schedule: $schedule)
                    Toggle("Summarize new items automatically", isOn: $autoSummarize)
                    Stepper(
                        "Items per check: \(retrievalCount)",
                        value: $retrievalCount,
                        in: 1...100
                    )
                    HStack {
                        Button {
                            Task { await model.checkSelectedChannel() }
                        } label: {
                            if model.isCheckingChannel {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Fetch fresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isCheckingChannel)
                        Button {
                            Task {
                                await model.checkSelectedChannel(loadMore: true)
                            }
                        } label: {
                            Label("Load more", systemImage: "arrow.down")
                        }
                        .disabled(model.isCheckingChannel || !channel.canLoadMore)
                    }
                    HStack {
                        Text("\(model.newChannelSources.count) " +
                             (model.newChannelSources.count == 1 ? "source" : "sources"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save changes", action: saveSettings)
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.newChannelSources.isEmpty ||
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
                    model.navigateBack()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(model.selectedChannelSource == "new" ? "Add channel" : "Channel")
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
        .task(id: model.selectedChannelSource) {
            source = ""
            retrievalCount = model.selectedChannel?.retrievalCount ?? 5
            autoSummarize = model.selectedChannel?.autoSummarize ?? true
            schedule = model.selectedChannel?.schedule ?? "manual"
            channelTitle = model.selectedChannel?.title ?? ""
            model.newChannelSources = model.selectedChannelSource == "new"
                ? []
                : model.selectedChannel?.sources ?? []
            model.channelBrowserAddress = ""
            model.channelBrowserStagesSource = model.selectedChannelSource == "new"
        }
        .confirmationDialog("Delete this channel?", isPresented: $confirmsRemoval) {
            Button("Delete Channel and Items", role: .destructive) {
                Task { await model.removeSelectedChannel() }
            }
        } message: {
            let count = model.selectedChannel.map {
                model.channelEntries(for: $0.source).count
            } ?? 0
            Text(
                count == 1
                    ? "The channel and its 1 downloaded item will be moved to Trash."
                    : "The channel and its \(count) downloaded items will be moved to Trash."
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
                Text("\(model.newChannelSources.count) " +
                     (model.newChannelSources.count == 1 ? "source" : "sources") + " added")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.newChannelSources = []
                    model.navigateBack()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Create channel") {
                    Task { await model.createChannel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.newChannelSources.isEmpty)
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
        model.stageChannelSource(source)
        source = ""
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
                    model.channelBrowserAddress = ""
                    model.channelBrowserStagesSource = true
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

        if !model.newChannelSources.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(listTitle)
                    .font(.headline)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(model.newChannelSources, id: \.self) { source in
                        ChannelSourceCard(
                            source: source,
                            openInBrowser: allowsOpening ? {
                                model.channelBrowserAddress = source
                                model.channelBrowserStagesSource = false
                                showsChannelBrowser = true
                            } : nil,
                            remove: {
                                model.removeStagedChannelSource(source)
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
            await model.updateSelectedChannel(
                title: channelTitle,
                sources: model.newChannelSources,
                retrievalCount: retrievalCount,
                autoSummarize: autoSummarize,
                schedule: schedule
            )
        }
    }
}

private struct ChannelSourceCard: View {
    let source: String
    let openInBrowser: (() -> Void)?
    let remove: () -> Void

    private var displaySource: String {
        guard let url = URL(string: source) else { return source }
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? source
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    private var symbol: String {
        guard let host = URL(string: source)?.host?.lowercased() else { return "globe" }
        if host.contains("youtube") { return "play.fill" }
        if host.contains("podcast") || host.contains("spotify") { return "waveform" }
        if host == "x.com" || host.hasSuffix("twitter.com") { return "at" }
        if host.contains("reddit") { return "bubble.left.and.bubble.right.fill" }
        return "globe"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text(displaySource)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let openInBrowser {
                Button(action: openInBrowser) {
                    Image(systemName: "globe")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open \(displaySource) in browser")
            }
            Button(action: remove) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(displaySource)")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct ConfigurationCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(eyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 28, weight: .bold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            content
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(24)
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #endif
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

#if os(macOS)
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: CaptureShortcut

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onShortcut = { shortcut = $0 }
        button.displayedShortcut = shortcut
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onShortcut = { shortcut = $0 }
        button.displayedShortcut = shortcut
    }

    final class RecorderButton: NSButton {
        var onShortcut: (CaptureShortcut) -> Void = { _ in }
        var displayedShortcut = CaptureShortcut.defaultValue {
            didSet {
                if !recording { title = displayedShortcut.label }
            }
        }
        private var recording = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            title = displayedShortcut.label
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            recording = true
            title = "Press shortcut…"
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if
                event.keyCode == UInt16(kVK_Escape),
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            {
                _ = window?.makeFirstResponder(nil)
                return
            }
            guard let value = CaptureShortcut(event: event) else {
                NSSound.beep()
                return
            }
            onShortcut(value)
            _ = window?.makeFirstResponder(nil)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            title = displayedShortcut.label
            return super.resignFirstResponder()
        }
    }
}
#endif

private enum BrieflySettingsSection: String, CaseIterable, Identifiable {
    case general
    case library
    case capture
    case account
    case personalization
    case topics
    case ai

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Appearance"
        case .library: "Library & Sync"
        case .capture: "Capture"
        case .account: "Account"
        case .personalization: "Personalization"
        case .topics: "Topics"
        case .ai: "AI Processing"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .library: "folder"
        case .capture: "keyboard"
        case .account: "person.crop.circle"
        case .personalization: "person.text.rectangle"
        case .topics: "number"
        case .ai: "sparkles"
        }
    }
}

#if os(macOS)
struct MacXSettingsWorkspace: View {
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    @AppStorage("BrieflySaveCapturedAudio") private var saveCapturedAudio = false
    @Bindable var model: LibraryModel
    @State private var selectedSection = BrieflySettingsSection.general
    @State private var query = ""
    @State private var captureShortcut = CaptureShortcut.load()
    @State private var shortcutRegistered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )
    @State private var showsChannelBrowser = false
    @State private var showsPDFImporter = false
    @State private var appleSignInNonce = ""

    private var filteredSections: [BrieflySettingsSection] {
        guard !query.isEmpty else { return BrieflySettingsSection.allCases }
        return BrieflySettingsSection.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                subtitle(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsIndex
                .frame(width: 390)

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(.ultraThinMaterial.opacity(0.48))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        .fileImporter(isPresented: $showsPDFImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                Task { await model.capturePDF(url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            ChannelLoginView()
        }
        .onChange(of: captureShortcut) {
            captureShortcut.save()
            NotificationCenter.default.post(
                name: .brieflyCaptureShortcutChanged,
                object: nil
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .brieflyCaptureShortcutRegistrationChanged
            )
        ) { notification in
            shortcutRegistered = notification.object as? Bool ?? false
        }
        .task {
            await model.refreshAccount()
            await model.loadSubscription()
        }
    }

    private var settingsIndex: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 18)
                .padding(.top, 17)
                .padding(.bottom, 14)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Settings", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.09)) }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSections) { section in
                        Button { selectedSection = section } label: {
                            HStack(spacing: 12) {
                                Image(systemName: section.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                        .font(.callout.weight(.medium))
                                    Text(subtitle(for: section))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 55)
                            .background(
                                selectedSection == section
                                    ? Color.primary.opacity(0.055)
                                    : .clear
                            )
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(selectedSection == section ? Color.accentColor : .clear)
                                    .frame(width: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().padding(.vertical, 8)
                    indexLink("Feedback", icon: "bubble.left.and.bubble.right", url: "https://www.readbriefly.fyi/feedback")
                    indexLink("Privacy Policy", icon: "hand.raised", url: "https://www.readbriefly.fyi/privacy")
                    indexLink("Terms of Use", icon: "doc.text", url: "https://www.readbriefly.fyi/terms")
                }
            }
        }
        .background(.ultraThinMaterial.opacity(0.42))
        .overlay(alignment: .trailing) { Divider() }
    }

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedSection.title)
                        .font(.title2.weight(.bold))
                    Text(detailSubtitle(for: selectedSection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

                Divider()
                detailContent
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general:
            detailGroup("Display") {
                detailRow(icon: "circle.lefthalf.filled", title: "Appearance", subtitle: "Choose how Briefly looks on this Mac") {
                    Picker("", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }

        case .library:
            detailGroup("Library") {
                valueRow(icon: "internaldrive", title: "Storage", value: "Local SQLite database")
                valueRow(icon: "checkmark.circle", title: "Status", value: model.status)
                actionRow(icon: "arrow.clockwise", title: "Refresh library", subtitle: "Reload all saved notes from local storage") {
                    Task { await model.refreshLibrary() }
                }
                actionRow(icon: "arrow.triangle.2.circlepath", title: model.isSyncing ? "Syncing…" : "Sync with iCloud", subtitle: "Push and pull the latest library changes") {
                    Task { await model.sync() }
                }
                .disabled(model.isSyncing)
            }

        case .capture:
            detailGroup("Capture") {
                detailRow(icon: "keyboard", title: "Global shortcut", subtitle: shortcutRegistered ? "Active system-wide" : "Choose another shortcut") {
                    ShortcutRecorder(shortcut: $captureShortcut)
                        .frame(width: 150, height: 30)
                }
                actionRow(icon: "clipboard", title: "Capture clipboard", subtitle: "Save the current clipboard as a note") {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    Task { await model.capture(text) }
                }
                .disabled(!model.canEdit)
                actionRow(icon: "doc.richtext", title: "Import PDF", subtitle: "Add and process a local PDF document") {
                    showsPDFImporter = true
                }
                .disabled(!model.canEdit)
                actionRow(icon: "globe", title: "Signed-in browser", subtitle: "Capture pages that require a login") {
                    showsChannelBrowser = true
                }
                detailRow(icon: "waveform", title: "Save captured YouTube audio", subtitle: "Applies to manual link captures") {
                    Toggle("", isOn: $saveCapturedAudio)
                        .labelsHidden()
                }
            }

        case .account:
            detailGroup("Your account") {
                valueRow(icon: "person.crop.circle", title: "Account", value: model.account.authenticated ? model.account.email ?? "Signed in" : "Signed out")
                if model.account.authenticated {
                    valueRow(icon: "checkmark.seal", title: "Membership", value: model.account.entitled == true ? "Active" : "Needs activation")
                    actionRow(icon: "arrow.clockwise", title: "Refresh account", subtitle: "Check membership and subscription status") {
                        Task { await model.refreshAccount(reportErrors: true) }
                    }
                    if model.account.entitled == true {
                        externalDetailRow(icon: "creditcard", title: "Manage App Store subscription", url: "https://apps.apple.com/account/subscriptions")
                    } else if let product = model.subscriptionProduct {
                        actionRow(icon: "sparkles", title: "Subscribe — \(product.displayPrice)/month", subtitle: "Unlock Briefly membership") {
                            Task { await model.purchaseSubscription() }
                        }
                    }
                    actionRow(icon: "arrow.counterclockwise", title: "Restore purchases", subtitle: "Restore an existing App Store subscription") {
                        Task { await model.restoreSubscription() }
                    }
                    actionRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign out", subtitle: "Remove this account from the Mac", destructive: true) {
                        Task { await model.signOut() }
                    }
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        let nonce = randomAppleNonce()
                        appleSignInNonce = nonce
                        request.requestedScopes = [.email]
                        request.nonce = SHA256.hash(data: Data(nonce.utf8))
                            .map { String(format: "%02x", $0) }
                            .joined()
                    } onCompletion: { result in
                        let nonce = appleSignInNonce
                        appleSignInNonce = ""
                        Task { await model.signInWithApple(result, nonce: nonce) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(width: 260, height: 42)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }

        case .personalization:
            editorGroup(
                title: "Personalization",
                description: "Context used when Prioritize for me is enabled.",
                firstTitle: "About you",
                firstText: $model.aboutYou,
                save: model.savePersonalizationSettings
            )

        case .topics:
            detailGroup("Topics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("One reusable topic per line, written as “id: Title”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.topicsText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(10)
                        .background(Color.primary.opacity(0.04))
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    HStack {
                        Spacer()
                        Button("Save topics") { Task { await model.saveTopics() } }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(20)
            }

        case .ai:
            detailGroup("AI processing") {
                detailRow(icon: "sparkles", title: "Use Briefly AI", subtitle: "Managed processing with zero-data retention") {
                    Toggle("", isOn: Binding(get: { model.usesManagedAI }, set: model.useManagedAI))
                        .labelsHidden()
                }
                if !model.usesManagedAI {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Processing command")
                            .font(.callout.weight(.semibold))
                        TextField("Command", text: $model.processingCommand, axis: .vertical)
                            .textFieldStyle(.plain)
                            .padding(11)
                            .background(Color.primary.opacity(0.04))
                            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    }
                    .padding(20)
                    Divider().padding(.leading, 58)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Processing prompt")
                        .font(.callout.weight(.semibold))
                    TextEditor(text: $model.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 230)
                        .padding(10)
                        .background(Color.primary.opacity(0.04))
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                    HStack {
                        Button("Restore default") { model.processingPrompt = defaultProcessingPrompt }
                        Button("Test") { Task { await model.testProcessingCommand() } }
                            .disabled(model.isTestingAI)
                        Spacer()
                        Button("Save") { model.saveProcessingSettings() }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(20)
            }
        }
    }

    private func detailGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            content()
        }
    }

    private func detailRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        detailRow(icon: icon, title: title, subtitle: value) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        subtitle: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .foregroundStyle(destructive ? Color.red : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func externalDetailRow(icon: String, title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 13) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
        }
        .foregroundStyle(.primary)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 57) }
    }

    private func editorGroup(
        title: String,
        description: String,
        firstTitle: String,
        firstText: Binding<String>,
        save: @escaping () -> Void
    ) -> some View {
        detailGroup(title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(description).font(.caption).foregroundStyle(.secondary)
                Text(firstTitle).font(.callout.weight(.semibold))
                TextField(firstTitle, text: firstText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...7)
                    .padding(11)
                    .background(Color.primary.opacity(0.04))
                    .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
                HStack {
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(20)
        }
    }

    private func indexLink(_ title: String, icon: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
        }
        .foregroundStyle(.primary)
    }

    private func subtitle(for section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Color scheme and display"
        case .library: "Storage, refresh, and iCloud"
        case .capture: "Shortcut, imports, and media"
        case .account: "Sign-in and subscription"
        case .personalization: "Your context"
        case .topics: "Reusable library topics"
        case .ai: "Provider, command, and prompt"
        }
    }

    private func detailSubtitle(for section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Manage how Briefly content is displayed to you."
        case .library: "Manage local storage, refresh, and synchronization."
        case .capture: "Choose how links and documents enter your library."
        case .account: "See account information and manage your membership."
        case .personalization: "Tell Briefly what matters to you."
        case .topics: "Manage the reusable topics applied to saved notes."
        case .ai: "Choose how Briefly processes and summarizes content."
        }
    }
}
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("BrieflyAppearance") private var appearance = "system"
    @AppStorage("BrieflySaveCapturedAudio") private var saveCapturedAudio = false
    #if os(macOS)
    @State private var captureShortcut = CaptureShortcut.load()
    @State private var shortcutRegistered = UserDefaults.standard.bool(
        forKey: "BrieflyCaptureShortcutRegistered"
    )
    #endif
    @Bindable var model: LibraryModel
    @State private var showsChannelBrowser = false
    @State private var appleSignInNonce = ""
    @State private var showsPDFImporter = false
    @State private var settingsQuery = ""
    #if os(iOS)
    @State private var selectedSection: BrieflySettingsSection?
    #else
    @State private var selectedSection: BrieflySettingsSection? = .general
    #endif

    private var availableSections: [BrieflySettingsSection] {
        BrieflySettingsSection.allCases
    }

    private func settingsRow(
        _ section: BrieflySettingsSection,
        value: String? = nil
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
            Text(section.title)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .tag(section)
    }

    private func externalSettingsRow(
        _ title: String,
        icon: String,
        destination: String
    ) -> some View {
        Link(destination: URL(string: destination)!) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityHint("Opens in your browser")
    }

    var body: some View {
        NavigationSplitView {
            #if os(iOS)
            List(selection: $selectedSection) {
                Section("General settings") {
                    settingsRow(
                        .account,
                        value: model.account.authenticated ? "Signed in" : "Signed out"
                    )
                    settingsRow(
                        .general,
                        value: appearance == "system" ? "Auto" : appearance.capitalized
                    )
                    settingsRow(.library)
                }

                Section("Briefly") {
                    settingsRow(.capture)
                    settingsRow(.personalization)
                }

                Section("Advanced") {
                    settingsRow(.topics)
                    settingsRow(.ai)
                }

                Section("Help") {
                    externalSettingsRow(
                        "Feedback",
                        icon: "bubble.left.and.bubble.right",
                        destination: "https://www.readbriefly.fyi/feedback"
                    )
                }

                Section("Legal") {
                    externalSettingsRow(
                        "Terms of Use",
                        icon: "doc.text",
                        destination: "https://www.readbriefly.fyi/terms"
                    )
                    externalSettingsRow(
                        "Privacy Policy",
                        icon: "hand.raised",
                        destination: "https://www.readbriefly.fyi/privacy"
                    )
                    externalSettingsRow(
                        "Imprint",
                        icon: "building.columns",
                        destination: "https://www.readbriefly.fyi/imprint"
                    )
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(readerBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Settings", text: $settingsQuery)
                        .textFieldStyle(.plain)
                    if !settingsQuery.isEmpty {
                        Button {
                            settingsQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(Color.primary.opacity(0.055), in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(0.09)) }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSettingsSections) { section in
                            Button {
                                selectedSection = section
                            } label: {
                                settingsNavigationRow(section)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider().padding(.vertical, 8)

                        externalSettingsRow(
                            "Feedback",
                            icon: "bubble.left.and.bubble.right",
                            destination: "https://www.readbriefly.fyi/feedback"
                        )
                        .padding(.horizontal, 16)
                        externalSettingsRow(
                            "Privacy Policy",
                            icon: "hand.raised",
                            destination: "https://www.readbriefly.fyi/privacy"
                        )
                        .padding(.horizontal, 16)
                        externalSettingsRow(
                            "Terms of Use",
                            icon: "doc.text",
                            destination: "https://www.readbriefly.fyi/terms"
                        )
                        .padding(.horizontal, 16)
                    }
                }
            }
            .background(.ultraThinMaterial.opacity(0.56))
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
            .navigationSplitViewColumnWidth(min: 370, ideal: 390, max: 410)
            #endif
        } detail: {
            NavigationStack {
                Form {
                    switch selectedSection ?? .general {
                    case .general:
                Section("Appearance") {
                    Picker("Mode", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                    case .library:
                Section("Library") {
                    LabeledContent("Storage", value: "Local SQLite database")
                    LabeledContent("Status", value: model.status)
                    if model.isSyncing {
                        SyncActivityView(model: model)
                            .padding(.vertical, 4)
                    }
                    if model.canEdit {
                        Button {
                            Task { await model.refreshLibrary() }
                        } label: {
                            Label("Refresh library", systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Label(
                            model.isSyncing ? "Syncing…" : "Sync with iCloud",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(model.isSyncing)
                }

                    case .capture:
                #if os(macOS)
                Section("Capture shortcut") {
                    HStack {
                        ShortcutRecorder(shortcut: $captureShortcut)
                            .frame(width: 150, height: 30)
                        Button("Reset") {
                            captureShortcut = .defaultValue
                        }
                        .disabled(captureShortcut == .defaultValue)
                    }
                    Text(
                        shortcutRegistered
                            ? "Active system-wide. Click the field and press a replacement shortcut."
                            : "This shortcut is unavailable; choose another combination."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                #endif

                Section("Capture tools") {
                    #if os(macOS)
                    if model.canEdit {
                        Button {
                            let text = NSPasteboard.general.string(forType: .string) ?? ""
                            Task { await model.capture(text) }
                        } label: {
                            Label("Capture clipboard", systemImage: "clipboard")
                        }
                    }
                    #endif
                    if model.canEdit {
                        Button {
                            showsPDFImporter = true
                        } label: {
                            Label("Import PDF", systemImage: "doc.richtext")
                        }
                    }
                    Button {
                        showsChannelBrowser = true
                    } label: {
                        Label("Signed-in browser", systemImage: "globe")
                    }
                }
                Section("Media") {
                    Toggle("Save captured YouTube audio", isOn: $saveCapturedAudio)
                    Text("Applies to manual link captures. Podcast episode audio remains streamed from its source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                    case .account:
                Section("Briefly account") {
                    LabeledContent(
                        "Status",
                        value: model.account.authenticated
                            ? model.account.email ?? "Signed in"
                            : "Signed out"
                    )
                    if model.account.authenticated {
                        LabeledContent(
                            "Membership",
                            value: model.account.entitled == true
                                ? "Active"
                                : "Needs activation"
                        )
                    }
                    HStack {
                        if model.account.authenticated {
                            Button("Sign out", role: .destructive) {
                                Task { await model.signOut() }
                            }
                        }
                        Spacer()
                        Button {
                            Task { await model.refreshAccount(reportErrors: true) }
                        } label: {
                            if model.isCheckingAccount {
                                ProgressView()
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(model.isCheckingAccount)
                    }
                    if model.account.authenticated {
                        if model.account.entitled == true {
                            Link(
                                "Manage App Store subscription",
                                destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                            )
                        } else if let product = model.subscriptionProduct {
                            Button("Subscribe — \(product.displayPrice)/month") {
                                Task { await model.purchaseSubscription() }
                            }
                            .disabled(model.isPurchasingSubscription)
                        } else {
                            Text("The subscription is not available from the App Store yet.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Restore purchases") {
                            Task { await model.restoreSubscription() }
                        }
                        .disabled(model.isPurchasingSubscription)
                    } else {
                        SignInWithAppleButton(.signIn) { request in
                            let nonce = randomAppleNonce()
                            appleSignInNonce = nonce
                            request.requestedScopes = [.email]
                            request.nonce = SHA256.hash(data: Data(nonce.utf8))
                                .map { String(format: "%02x", $0) }
                                .joined()
                        } onCompletion: { result in
                            let nonce = appleSignInNonce
                            appleSignInNonce = ""
                            Task { await model.signInWithApple(result, nonce: nonce) }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(maxWidth: 280, minHeight: 42, maxHeight: 42)
                        .accessibilityLabel("Sign in with Apple")
                    }
                }

                    case .personalization:
                Section("Personalization") {
                    TextField(
                        "About you",
                        text: $model.aboutYou,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    Text("Used only when “Prioritize for me” is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Save") {
                            model.savePersonalizationSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                    case .topics:
                if model.canEdit {
                    Section("Topics") {
                        Text("One reusable topic per line, written as “id: Title”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.topicsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                        HStack {
                            Spacer()
                            Button("Save topics") {
                                Task { await model.saveTopics() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Topics need a library",
                        systemImage: "folder",
                        description: Text("Open a Briefly library to edit topics.")
                    )
                }

                    case .ai:
                Section("AI processing") {
                    #if os(macOS)
                    Toggle(
                        "Use Briefly AI",
                        isOn: Binding(
                            get: { model.usesManagedAI },
                            set: model.useManagedAI
                        )
                    )
                    if !model.usesManagedAI {
                        Menu("Choose processing preset") {
                            Button("Codex") {
                                model.processingCommand =
                                    defaultProcessingCommand
                            }
                            Button("Claude") {
                                model.processingCommand =
                                    #"claude -p --tools "" --strict-mcp-config --no-session-persistence"#
                            }
                            Button("Pi") {
                                model.processingCommand =
                                    "pi -p --no-tools --no-session --no-context-files --no-extensions --no-skills"
                            }
                            Button("OpenCode") {
                                model.processingCommand =
                                    #"opencode run --pure "$(cat)""#
                            }
                        }
                        TextField(
                            "Command",
                            text: $model.processingCommand,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                    } else {
                        Text(
                            "Briefly AI via OpenRouter, covered by a zero-data-retention agreement."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    #else
                    Label("Briefly AI", systemImage: "sparkles")
                    Text(
                        "Briefly AI via OpenRouter, covered by a zero-data-retention agreement."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    #endif
                    TextEditor(text: $model.processingPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                    HStack {
                        Button("Restore default prompt") {
                            model.processingPrompt = defaultProcessingPrompt
                        }
                        #if os(macOS)
                        Button {
                            Task { await model.testProcessingCommand() }
                        } label: {
                            if model.isTestingAI {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test command")
                            }
                        }
                        .disabled(model.isTestingAI)
                        #endif
                        Spacer()
                        Button("Save") {
                            model.saveProcessingSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial.opacity(0.72))
                .navigationTitle((selectedSection ?? .general).title)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
            }
        }
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.48))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        .onChange(of: captureShortcut) {
            captureShortcut.save()
            NotificationCenter.default.post(
                name: .brieflyCaptureShortcutChanged,
                object: nil
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .brieflyCaptureShortcutRegistrationChanged
            )
        ) { notification in
            shortcutRegistered = notification.object as? Bool ?? false
        }
        #endif
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    await model.capturePDF(url)
                    dismiss()
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsChannelBrowser) {
            ChannelLoginView()
        }
        .task {
            await model.refreshAccount()
            await model.loadSubscription()
        }
    }

    private var filteredSettingsSections: [BrieflySettingsSection] {
        guard !settingsQuery.isEmpty else { return availableSections }
        return availableSections.filter {
            $0.title.localizedCaseInsensitiveContains(settingsQuery)
        }
    }

    private func settingsNavigationRow(_ section: BrieflySettingsSection) -> some View {
        let selected = selectedSection == section
        return HStack(spacing: 12) {
            Image(systemName: section.icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.callout.weight(.medium))
                Text(settingsSubtitle(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(selected ? Color.primary.opacity(0.055) : .clear)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(selected ? Color.accentColor : .clear)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
    }

    private func settingsSubtitle(_ section: BrieflySettingsSection) -> String {
        switch section {
        case .general: "Color scheme and display"
        case .library: "Storage, refresh, and iCloud"
        case .capture: "Shortcut, imports, and media"
        case .account: "Sign-in and subscription"
        case .personalization: "Your context"
        case .topics: "Reusable library topics"
        case .ai: "Provider, command, and prompt"
        }
    }
}

private func randomAppleNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        return UUID().uuidString
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
