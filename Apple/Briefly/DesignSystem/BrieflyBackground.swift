import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif

enum BrieflyBackgroundAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum BrieflyBackgroundStore {
    static let revisionKey = "BrieflyCustomBackgroundRevision"
    private static let maximumFileSize = 50 * 1_024 * 1_024

    static func hasCustomImage(for appearance: BrieflyBackgroundAppearance) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: appearance).path)
    }

    static func customImage(for appearance: BrieflyBackgroundAppearance) -> Image? {
        let url = fileURL(for: appearance)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
        #endif
    }

    static func importImage(
        from sourceURL: URL,
        for appearance: BrieflyBackgroundAppearance
    ) throws {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try save(Data(contentsOf: sourceURL, options: .mappedIfSafe), for: appearance)
    }

    static func save(
        _ data: Data,
        for appearance: BrieflyBackgroundAppearance
    ) throws {
        guard data.count <= maximumFileSize else {
            throw BrieflyBackgroundError.imageTooLarge
        }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else {
            throw BrieflyBackgroundError.invalidImage
        }

        let directory = directoryURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL(for: appearance), options: .atomic)
        markChanged()
    }

    static func removeImage(for appearance: BrieflyBackgroundAppearance) throws {
        let url = fileURL(for: appearance)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            markChanged()
        }
    }

    private static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Briefly", directoryHint: .isDirectory)
            .appending(path: "Backgrounds", directoryHint: .isDirectory)
    }

    private static func fileURL(for appearance: BrieflyBackgroundAppearance) -> URL {
        directoryURL.appending(path: "custom-\(appearance.rawValue)-background")
    }

    private static func markChanged() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }
}

private enum BrieflyBackgroundError: LocalizedError {
    case imageTooLarge
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .imageTooLarge: "Choose an image smaller than 50 MB."
        case .invalidImage: "The selected file could not be read as an image."
        }
    }
}

struct BrieflyBackgroundImage: View {
    let appearance: BrieflyBackgroundAppearance
    @AppStorage(BrieflyBackgroundStore.revisionKey) private var revision = 0

    var body: some View {
        Group {
            if let image = customImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(defaultImageName)
                    .resizable()
                    .scaledToFill()
            }
        }
        .environment(\.colorScheme, appearance == .dark ? .dark : .light)
        .accessibilityHidden(true)
    }

    private var customImage: Image? {
        _ = revision
        return BrieflyBackgroundStore.customImage(for: appearance)
    }

    private var defaultImageName: String {
        #if os(macOS)
        "BrieflyBackgroundDesktop"
        #else
        "BrieflyBackgroundMobile"
        #endif
    }
}

struct BrieflyBackgroundSetting: View {
    let appearance: BrieflyBackgroundAppearance
    @AppStorage(BrieflyBackgroundStore.revisionKey) private var revision = 0
    @State private var errorMessage: String?
    #if os(macOS)
    @State private var showsImporter = false
    #else
    @State private var selectedPhoto: PhotosPickerItem?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                BrieflyBackgroundImage(appearance: appearance)
                    .frame(width: previewWidth, height: previewHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.14))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(appearance.title) mode")
                        .font(.callout.weight(.medium))
                    Text(hasCustomImage ? "Custom image" : "Briefly default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                #if os(macOS)
                Button(hasCustomImage ? "Replace Image" : "Choose Image") {
                    showsImporter = true
                }
                #else
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Text(hasCustomImage ? "Replace Photo" : "Choose Photo")
                }
                #endif

                if hasCustomImage {
                    Button("Use Default", role: .destructive) {
                        do {
                            try BrieflyBackgroundStore.removeImage(for: appearance)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        #if os(macOS)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.image]) { result in
            do {
                try BrieflyBackgroundStore.importImage(
                    from: result.get(),
                    for: appearance
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        #else
        .onChange(of: selectedPhoto) {
            guard let selectedPhoto else { return }
            Task {
                do {
                    guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                        throw BrieflyBackgroundError.invalidImage
                    }
                    try BrieflyBackgroundStore.save(data, for: appearance)
                } catch {
                    errorMessage = error.localizedDescription
                }
                self.selectedPhoto = nil
            }
        }
        #endif
        .alert(
            "Couldn’t Update Background",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var hasCustomImage: Bool {
        _ = revision
        return BrieflyBackgroundStore.hasCustomImage(for: appearance)
    }

    private var previewWidth: CGFloat {
        #if os(macOS)
        104
        #else
        74
        #endif
    }

    private var previewHeight: CGFloat {
        #if os(macOS)
        64
        #else
        52
        #endif
    }
}
