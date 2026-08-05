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

func extendsSidebarSelection() -> Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.command)
    #else
    false
    #endif
}

struct FaviconImage: View {
    let url: URL
    let fallback: String

    var body: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            fallbackImage
        }
        #else
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            fallbackImage
        }
        #endif
    }

    private var fallbackImage: some View {
        Image(systemName: fallback)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 17)
    }
}

struct SidebarEmpty: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}
func channelTitle(_ source: String) -> String {
    guard let host = URL(string: source)?.host?.lowercased() else {
        return source
    }
    if host.contains("arxiv.org") { return "ArXiv" }
    if host.contains("ycombinator.com") { return "Hacker News" }
    if host.contains("reddit.com") { return "Reddit" }
    if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") {
        return "X"
    }
    return host
        .replacingOccurrences(of: "www.", with: "")
        .split(separator: ".")
        .first
        .map { String($0).capitalized } ?? source
}

func compactLabel(_ value: String, maxLength: Int = 28) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
}

func localFaviconURL(
    for entry: LibraryEntry
) -> URL? {
    guard let favicon = entry.favicon else { return nil }
    let url = URL(fileURLWithPath: favicon.path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}
