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

#if os(macOS)
struct SidebarTopic: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

struct MacSidebarFilters: View {
    @Bindable var model: LibraryModel

    private var notes: [LibraryEntry] {
        model.session.projection.entries.filter(\.isMainLibraryEntry)
    }

    private var topics: [SidebarTopic] {
        model.session.projection.documentTopics.map { topic in
            SidebarTopic(
                name: topic,
                count: notes.count { $0.topicNames.contains(topic) }
            )
        }
        .sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        LazyVStack(spacing: 2) {
            switch model.navigation.activeSection {
            case .items:
                SidebarRow(
                    icon: "tray",
                    title: "Inbox",
                    count: notes.count,
                    selected: model.navigation.selectedTopic == "All" &&
                        !model.navigation.showingHighlights && !model.navigation.showingTrash,
                    action: model.navigation.showInbox
                )
                SidebarRow(
                    icon: "highlighter",
                    title: "Highlights",
                    count: model.selection.loadedHighlightCount,
                    selected: model.navigation.showingHighlights,
                    action: model.navigation.showHighlights
                )
                SidebarRow(
                    icon: "trash",
                    title: "Trash",
                    count: model.selection.loadedTrashCount,
                    selected: model.navigation.showingTrash,
                    action: model.navigation.showTrash
                )

                if !topics.isEmpty {
                    SidebarSectionHeader("Collections")
                    ForEach(topics) { topic in
                        SidebarRow(
                            icon: "folder",
                            title: topic.name,
                            count: topic.count,
                            selected: model.navigation.selectedTopic == topic.name &&
                                !model.navigation.showingHighlights && !model.navigation.showingTrash
                        ) {
                            Task { await model.navigation.showTopic(topic.name) }
                        }
                    }
                }

            case .channels:
                SidebarRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "All Channels",
                    count: model.channels.channels.count,
                    selected: model.navigation.selectedChannelDomain == "All"
                ) {
                    model.navigation.showChannelDomain("All")
                }
                if !model.channels.channels.isEmpty {
                    SidebarSectionHeader("Domains")
                    ForEach(channelDomainGroups(model.channels.channels)) { group in
                        SidebarRow(
                            icon: "globe",
                            title: group.domain,
                            count: group.channels.count,
                            selected: model.navigation.selectedChannelDomain == group.domain
                        ) {
                            model.navigation.showChannelDomain(group.domain)
                        }
                    }
                }

            case .briefs:
                SidebarRow(
                    icon: "headphones",
                    title: "All",
                    count: model.session.projection.entries.count {
                        $0.entryType == "voice_brief_episode"
                    },
                    selected: model.navigation.selectedVoiceBriefID.isEmpty
                ) {
                    model.navigation.selectVoiceBrief("")
                }
                if !model.session.projection.voiceBriefDefinitions.isEmpty {
                    SidebarSectionHeader("Voice Briefs")
                    ForEach(model.session.projection.voiceBriefDefinitions, id: \.id) { brief in
                        SidebarRow(
                            icon: "headphones",
                            title: brief.title,
                            count: model.session.projection.episodes(for: brief.id).count,
                            selected: model.navigation.selectedVoiceBriefID == brief.id
                        ) {
                            model.navigation.selectVoiceBrief(brief.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }
}
#endif
