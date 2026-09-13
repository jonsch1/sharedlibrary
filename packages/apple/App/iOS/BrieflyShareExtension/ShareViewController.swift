import BrieflyCore
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let errorLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let cancelButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 360, height: 230)

        let icon = UIImageView(image: UIImage(systemName: "square.and.arrow.down.fill"))
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        titleLabel.text = "Save to Briefly"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true

        messageLabel.text = "Save the original link, text, or PDF now. Open Briefly on your iPhone to sync it; your Mac prepares it."
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontForContentSizeCategory = true

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.adjustsFontForContentSizeCategory = true

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Save"
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 0
        configuration.imagePadding = 8
        saveButton.configuration = configuration
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)

        let heading = UIStackView(arrangedSubviews: [icon, titleLabel, UIView()])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 12

        let buttons = UIStackView(arrangedSubviews: [cancelButton, UIView(), activityIndicator, saveButton])
        buttons.axis = .horizontal
        buttons.alignment = .center
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [heading, messageLabel, errorLabel, buttons])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 18
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.bottomAnchor)
        ])
    }

    @objc private func cancel() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func save() {
        setSaving(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await enqueueSharedItem()
                titleLabel.text = "Saved to Briefly"
                messageLabel.text = "Saved on this device. Open Briefly to sync it to your Mac."
                try? await Task.sleep(for: .milliseconds(350))
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                setSaving(false)
                errorLabel.text = error.localizedDescription
                errorLabel.isHidden = false
            }
        }
    }

    private func setSaving(_ saving: Bool) {
        cancelButton.isEnabled = !saving
        saveButton.isEnabled = !saving
        if saving {
            errorLabel.isHidden = true
            activityIndicator.startAnimating()
            saveButton.configuration?.title = "Saving"
        } else {
            activityIndicator.stopAnimating()
            saveButton.configuration?.title = "Save"
        }
    }

    private func enqueueSharedItem() async throws {
        let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = inputItems.flatMap { $0.attachments ?? [] }.filter(isSupported)
        guard providers.count == 1, let provider = providers.first else {
            throw ShareExtensionError.shareOneSupportedItem
        }
        let inbox = try SharedCaptureInbox()

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await loadURL(from: provider),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            _ = try inbox.enqueue(url: url)
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            try await enqueuePDF(from: provider, into: inbox)
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let text = try await loadText(from: provider)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed),
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               url.host != nil,
               !trimmed.contains(where: \.isWhitespace) {
                _ = try inbox.enqueue(url: url)
            } else {
                _ = try inbox.enqueue(text: trimmed)
            }
            return
        }

        if let text = inputItems.compactMap(\.attributedContentText?.string).first {
            _ = try inbox.enqueue(text: text)
            return
        }
        throw ShareExtensionError.unsupportedItem
    }

    private func isSupported(_ provider: NSItemProvider) -> Bool {
        [UTType.url, .plainText, .pdf].contains {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let url: URL? = switch item {
                case let value as URL: value
                case let value as NSURL: value as URL
                case let value as String: URL(string: value)
                case let value as Data:
                    String(data: value, encoding: .utf8).flatMap(URL.init(string:))
                default: nil
                }
                guard let url else {
                    continuation.resume(throwing: ShareExtensionError.unsupportedItem)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.plainText.identifier,
                options: nil
            ) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let text: String? = switch item {
                case let value as String: value
                case let value as NSString: value as String
                case let value as Data: String(data: value, encoding: .utf8)
                default: nil
                }
                guard let text else {
                    continuation.resume(throwing: ShareExtensionError.unsupportedItem)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// `loadFileRepresentation` removes its temporary URL after this callback,
    /// so the inbox performs its durable copy before the continuation resumes.
    private func enqueuePDF(
        from provider: NSItemProvider,
        into inbox: SharedCaptureInbox
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ShareExtensionError.unsupportedItem }
                    _ = try inbox.enqueuePDF(at: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum ShareExtensionError: LocalizedError {
    case shareOneSupportedItem
    case unsupportedItem

    var errorDescription: String? {
        switch self {
        case .shareOneSupportedItem:
            "Share one link, text selection, or PDF at a time."
        case .unsupportedItem:
            "Briefly can save web links, text, and PDF documents."
        }
    }
}
