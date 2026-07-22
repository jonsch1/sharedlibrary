import AppKit

private enum AppLifetime {
    @MainActor static let delegate = AppDelegate()
}

// Menu bar app: no Dock icon, always resident. `.accessory` activation policy gives us
// LSUIElement behaviour even when launched directly, while still allowing key panels.
// Top-level code runs on the main thread; assume MainActor isolation for the app setup.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = AppLifetime.delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
