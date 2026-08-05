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

struct ChannelDomainGroup: Identifiable {
    let domain: String
    let channels: [LibraryChannel]

    var id: String { domain }
}

func channelDomainGroups(
    _ channels: [LibraryChannel]
) -> [ChannelDomainGroup] {
    Dictionary(grouping: channels, by: { channelDomain($0.primarySource) })
        .map { domain, channels in
            ChannelDomainGroup(
                domain: domain,
                channels: channels.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted {
            $0.channels.count != $1.channels.count
                ? $0.channels.count > $1.channels.count
                : $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }
}

func channelDomain(_ source: String) -> String {
    let host = URL(string: source)?.host?.lowercased()
        .replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ??
        "other"
    if host == "x.com" || host == "twitter.com" { return "x.com" }
    if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
        return "youtube.com"
    }
    if host == "reddit.com" || host.hasSuffix(".reddit.com") { return "reddit.com" }
    return host
}

struct SidebarRow: View {
    let icon: String
    let title: String
    var count: Int? = nil
    let selected: Bool
    var inset = false
    var imageURL: URL?
    var showsIcon = true
    var glass = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if glass {
            row.mobileGlass(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: selected ? Color.accentColor.opacity(0.18) : nil
            )
        } else {
            row
        }
        #else
        if selected {
            row.macLiquidGlass(
                in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                tint: Color(red: 0.43, green: 0.34, blue: 0.21).opacity(0.44),
                interactive: true
            )
        } else {
            row
        }
        #endif
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if showsIcon {
                    if let imageURL {
                        FaviconImage(url: imageURL, fallback: icon)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 17)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                        .accessibilityLabel("\(count) items")
                }
            }
            .padding(.leading, inset ? 27 : 11)
            .padding(.trailing, 11)
            .frame(minHeight: 37, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background {
            if !glass {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackgroundColor)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: glass ? 18 : 9,
                style: .continuous
            )
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rowBackgroundColor: Color {
        #if os(iOS)
        selected
            ? Color(red: 0.38, green: 0.10, blue: 0.72).opacity(0.34)
            : .clear
        #else
        .clear
        #endif
    }
}
