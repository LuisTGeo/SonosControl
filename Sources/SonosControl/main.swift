import AppKit

// Boot as a menu-bar agent (no Dock icon). `app.run()` never returns, so the
// delegate stays alive for the process lifetime.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
