import AppKit
import SwiftUI
import KeyboardShortcuts
import UserNotifications
import Network

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    private var statusItem: NSStatusItem!
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var captureTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?
    private var canPostUserNotifications = false
    private var libraryVisible = false
    private var backgroundSyncTimer: Timer?
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "SharedLibrary.NetworkMonitor")
    private var networkWasAvailable: Bool?
    private var lastBackgroundSyncRequestAt: Date?
    private let libraryWindowIdentifier = NSUserInterfaceItemIdentifier("SharedLibraryWorkspaceWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        registerHotkeys()
        setupNotifications()
        setupBackgroundSyncTriggers()
        Task {
            try? await GitHubCredentialVault.shared.clear()
        }
        env.googleDriveAuthorization.refreshStatus()
        requestBackgroundSync(reason: "app launched")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryAppearanceDidChange(_:)),
            name: .libraryAppearanceDidChange,
            object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        requestBackgroundSync(reason: "app became active", minimumInterval: 300)
    }

    func applicationWillTerminate(_ notification: Notification) {
        backgroundSyncTimer?.invalidate()
        networkMonitor.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !libraryVisible { showLibrary() }
        return false
    }

    // MARK: - Main menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Shared Library",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "books.vertical",
                                   accessibilityDescription: "Shared Library")
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Library", action: #selector(showLibrary), keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "")

        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyUp(for: .toggleLibrary) { [weak self] in
            self?.toggleLibraryWindow()
        }
        KeyboardShortcuts.onKeyUp(for: .captureClipboard) { [weak self] in
            self?.captureClipboard()
        }
    }

    // MARK: - Library window

    @objc func toggleLibraryWindow() {
        if libraryVisible {
            hideLibraryWindow()
        } else {
            showLibrary()
        }
    }

    @objc func showLibrary() {
        showLibraryWindow()
    }

    private func showLibraryWindow() {
        let window = libraryWindow ?? makeLibraryWindow()
        libraryWindow = window
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        layoutSidebarWindowControls(in: window)
        libraryVisible = true
    }

    private func hideLibraryWindow() {
        libraryWindow?.orderOut(nil)
        libraryVisible = false
    }

    private func makeLibraryWindow() -> NSWindow {
        let initialSize = NSSize(width: 1280, height: 720)
        let root = SharedLibraryWorkspaceView()
            .environmentObject(env)
            .background(VisualEffectBackground(material: .hudWindow).ignoresSafeArea())

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = libraryWindowIdentifier
        window.contentViewController = NSHostingController(rootView: root)
        window.contentMinSize = NSSize(width: 1040, height: 640)
        window.setContentSize(initialSize)
        window.title = "Shared Library"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.center()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        window.animationBehavior = .none
        window.delegate = self
        installSidebarWindowControls(in: window)
        return window
    }

    private func installSidebarWindowControls(in window: NSWindow) {
        if window.identifier == libraryWindowIdentifier {
            for buttonType in sidebarWindowButtonTypes {
                window.standardWindowButton(buttonType)?.isHidden = true
            }
            return
        }

        guard let contentView = window.contentView else { return }

        for buttonType in sidebarWindowButtonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            if button.frame.size == .zero {
                button.sizeToFit()
            }
            button.isHidden = false
            button.autoresizingMask = []

            if button.superview !== contentView {
                button.removeFromSuperview()
                contentView.addSubview(button, positioned: .above, relativeTo: nil)
            }
        }

        layoutSidebarWindowControls(in: window)
    }

    private func layoutSidebarWindowControls(in window: NSWindow) {
        if window.identifier == libraryWindowIdentifier {
            for buttonType in sidebarWindowButtonTypes {
                window.standardWindowButton(buttonType)?.isHidden = true
            }
            return
        }

        guard let contentView = window.contentView else { return }

        let leftInset: CGFloat = 38
        let topInset: CGFloat = 32
        let centerSpacing: CGFloat = 22

        for (index, buttonType) in sidebarWindowButtonTypes.enumerated() {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let size = button.frame.size == .zero
                ? NSSize(width: 14, height: 14)
                : button.frame.size
            let x = leftInset + (CGFloat(index) * centerSpacing)
            let y = contentView.isFlipped
                ? topInset
                : contentView.bounds.height - topInset - size.height
            button.frame = NSRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    @objc private func libraryAppearanceDidChange(_ notification: Notification) {
        guard let window = libraryWindow else { return }

        installSidebarWindowControls(in: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.installSidebarWindowControls(in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak window] in
            guard let self, let window else { return }
            self.installSidebarWindowControls(in: window)
        }
    }

    private var sidebarWindowButtonTypes: [NSWindow.ButtonType] {
        [.closeButton, .miniaturizeButton, .zoomButton]
    }

    // MARK: - Capture clipboard

    @objc private func captureClipboard() {
        captureTask?.cancel()

        let pasteboard = NSPasteboard.general
        let clipboardText = pasteboard.string(forType: .string) ?? ""
        let trimmedClipboardText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClipboardText.isEmpty else {
            setStatus(.failed("Clipboard does not contain text."))
            return
        }

        guard let url = Self.onlyURL(in: trimmedClipboardText) else {
            captureClipboardText(trimmedClipboardText)
            return
        }

        setStatus(.capturing(Self.shortDisplayURL(url)))

        let extractor = env.extractor
        let store = env.libraryStore
        captureTask = Task { [weak self, extractor, store, url] in
            do {
                let item = try await Task.detached(priority: .userInitiated) { [extractor, store, url] in
                    let extracted = try await extractor.extract(url: url)
                    return try store.save(extracted: extracted)
                }.value

                guard let self else { return }
                self.setStatus(.saved(item.title))
                self.postNotification(title: "Capture saved", body: item.title)
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                self.env.processingCoordinator.process(
                    item: item,
                    workspaceRootURL: self.env.settings.workspaceRootURL
                )
            } catch {
                guard let self else { return }
                self.setStatus(.failed(error.localizedDescription))
                self.postNotification(title: "Capture failed", body: error.localizedDescription)
            }
        }
    }

    private func captureClipboardText(_ text: String) {
        setStatus(.capturing("Clipboard text"))

        let sourceURL = Self.firstURL(in: text)
        let store = env.libraryStore
        captureTask = Task { [weak self, store, sourceURL, text] in
            do {
                let item = try await Task.detached(priority: .userInitiated) { [store, sourceURL, text] in
                    try store.saveText(text, sourceURL: sourceURL)
                }.value

                guard let self else { return }
                self.setStatus(.saved(item.title))
                self.postNotification(title: "Capture saved", body: item.title)
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                self.env.processingCoordinator.process(
                    item: item,
                    workspaceRootURL: self.env.settings.workspaceRootURL
                )
            } catch {
                guard let self else { return }
                self.setStatus(.failed(error.localizedDescription))
                self.postNotification(title: "Capture failed", body: error.localizedDescription)
            }
        }
    }

    // MARK: - Settings

    @objc func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let root = SettingsView().environmentObject(env)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shared Library Settings"
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.hidesOnDeactivate = false
        window.center()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none
        return window
    }

    @objc func quit() { NSApp.terminate(nil) }

    private func setStatus(_ state: LibraryStatus) {
        statusResetTask?.cancel()

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: state.systemSymbolName,
                                   accessibilityDescription: state.accessibilityDescription) {
                button.image = image
            }
            button.title = ""
            button.toolTip = state.detail.map { "Shared Library - \($0)" } ?? "Shared Library"
        }

        guard state.shouldAutoReset else { return }
        statusResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.setStatus(.ready)
            }
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(processingDidStart(_:)),
            name: .processingDidStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(processingDidFinish(_:)),
            name: .processingDidFinish,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(processingDidFail(_:)),
            name: .processingDidFail,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryShouldUpdateMobileExports(_:)),
            name: .libraryDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryShouldUpdateMobileExports(_:)),
            name: .workspaceDidSynchronize,
            object: nil
        )

        canPostUserNotifications = Bundle.main.bundleURL.pathExtension == "app"
        guard canPostUserNotifications else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setupBackgroundSyncTriggers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestBackgroundSync(reason: "periodic background sync")
            }
        }
        timer.tolerance = 60
        backgroundSyncTimer = timer

        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let connectivityWasRestored = self.networkWasAvailable == false && isAvailable
                self.networkWasAvailable = isAvailable
                if connectivityWasRestored {
                    self.requestBackgroundSync(reason: "network connectivity restored")
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        requestBackgroundSync(reason: "Mac woke from sleep")
    }

    private func requestBackgroundSync(
        reason: String,
        minimumInterval: TimeInterval = 0
    ) {
        let now = Date()
        if let lastBackgroundSyncRequestAt,
           now.timeIntervalSince(lastBackgroundSyncRequestAt) < minimumInterval {
            return
        }
        lastBackgroundSyncRequestAt = now
        env.googleDriveLibraryPublisher.requestAutomaticUpdate(reason: reason)
    }

    @objc private func processingDidStart(_ notification: Notification) {
        let sourceTitle = notification.userInfo?["sourceTitle"] as? String ?? "Capture"
        setStatus(.capturing("Processing \(sourceTitle)"))
    }

    @objc private func processingDidFinish(_ notification: Notification) {
        let sourceTitle = notification.userInfo?["sourceTitle"] as? String ?? "Capture"
        let topicName = notification.userInfo?["topicName"] as? String
        refreshSharedCopyAfterProcessing(notification)
        setStatus(.saved(sourceTitle))
        postNotification(
            title: "Capture organized",
            body: topicName.map { "\(sourceTitle) → \($0)" } ?? sourceTitle
        )
        env.googleDriveLibraryPublisher.requestAutomaticUpdate(reason: "the updated library")
    }

    @objc private func libraryShouldUpdateMobileExports(_ notification: Notification) {
        env.googleDriveLibraryPublisher.requestAutomaticUpdate(reason: "the updated library")
    }

    private func refreshSharedCopyAfterProcessing(_ notification: Notification) {
        guard let oldPath = notification.userInfo?["sourcePath"] as? String,
              let newPath = notification.userInfo?["processedPath"] as? String else { return }
        let oldURL = URL(fileURLWithPath: oldPath)
        let newURL = URL(fileURLWithPath: newPath)
        let privateWorkspaceURL = env.settings.workspaceRootURL
        let sharedWorkspaceURL = env.settings.sharedWorkspaceRootURL
        guard env.sharingStore.isShared(
            captureAt: oldURL,
            privateWorkspaceURL: privateWorkspaceURL,
            sharedWorkspaceURL: sharedWorkspaceURL
        ) else { return }

        do {
            try env.sharingStore.shareCapture(
                at: newURL,
                privateWorkspaceURL: privateWorkspaceURL,
                sharedWorkspaceURL: sharedWorkspaceURL
            )
            if oldURL.standardizedFileURL != newURL.standardizedFileURL {
                try env.sharingStore.retargetSharingReference(
                    from: oldURL,
                    to: newURL,
                    privateWorkspaceURL: privateWorkspaceURL,
                    sharedWorkspaceURL: sharedWorkspaceURL
                )
                try env.sharingStore.unshareCapture(
                    at: oldURL,
                    privateWorkspaceURL: privateWorkspaceURL,
                    sharedWorkspaceURL: sharedWorkspaceURL
                )
            }
            env.peopleStore.reloadFromDisk()
            env.googleDriveLibraryPublisher.requestAutomaticUpdate(reason: "the updated shared library")
        } catch {
            postNotification(title: "Shared copy update failed", body: error.localizedDescription)
        }
    }

    @objc private func processingDidFail(_ notification: Notification) {
        let message = notification.userInfo?["message"] as? String
            ?? "The capture could not be processed."
        setStatus(.failed(message))
        postNotification(title: "Processing failed", body: message)
        env.googleDriveLibraryPublisher.requestAutomaticUpdate(reason: "the saved capture")
    }

    private func postNotification(title: String, body: String) {
        guard canPostUserNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func firstURL(in text: String) -> String? {
        let pattern = #"https?://[^\s<>"')]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        var url = String(text[r])
        while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
        return url
    }

    private static func onlyURL(in text: String) -> String? {
        guard let url = firstURL(in: text), url == text else {
            return nil
        }
        return url
    }

    private static func shortDisplayURL(_ url: String) -> String {
        URL(string: url)?.host(percentEncoded: false) ?? url
    }

}

private enum LibraryStatus {
    case ready
    case capturing(String)
    case saved(String)
    case failed(String)

    var detail: String? {
        switch self {
        case .ready:
            return nil
        case .capturing(let value), .saved(let value), .failed(let value):
            return value
        }
    }

    var systemSymbolName: String {
        switch self {
        case .ready:
            return "books.vertical"
        case .capturing:
            return "arrow.triangle.2.circlepath"
        case .saved:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .ready:
            return "Shared Library"
        case .capturing:
            return "Shared Library is extracting"
        case .saved:
            return "Shared Library saved the item"
        case .failed:
            return "Shared Library failed"
        }
    }

    var shouldAutoReset: Bool {
        switch self {
        case .saved, .failed:
            return true
        case .ready, .capturing:
            return false
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == libraryWindow {
            hideLibraryWindow()
            return false
        }
        return true
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == libraryWindow else { return }
        layoutSidebarWindowControls(in: window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == libraryWindow else { return }
        layoutSidebarWindowControls(in: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == libraryWindow else { return }
        layoutSidebarWindowControls(in: window)
    }
}
