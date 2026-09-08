import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SonosController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        setUpWindow()
        setUpHotKey()
        // Warm discovery in the background so the list is ready on first click,
        // and open the panel so a direct launch has visible feedback.
        controller.refresh()
        DispatchQueue.main.async { [weak self] in
            self?.showWindow()
        }
    }

    // MARK: - Setup

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 52)
        if let button = statusItem.button {
            button.image = nil
            button.title = "Sonos"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setUpPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 560)
        popover.behavior = .transient   // closes when you click away
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(controller)
        )
        self.popover = popover
    }

    private func setUpWindow() {
        let content = NSHostingController(
            rootView: ContentView().environmentObject(controller)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SonosControl"
        window.contentViewController = content
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    private func setUpHotKey() {
        // ⌘⌥S toggles the panel from anywhere.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.togglePopover()
        }
    }

    // MARK: - Popover control

    @objc private func togglePopover() {
        if window.isVisible {
            window.orderOut(nil)
            controller.endLiveUpdates()
        } else {
            showWindow()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Make the popover window key so it takes focus immediately (matters when
        // opened via the global hotkey while another app is frontmost).
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        controller.beginLiveUpdates()
    }
}

extension AppDelegate: NSPopoverDelegate {
    // Poll the fast-changing state only while the panel is open.
    func popoverDidShow(_ notification: Notification) {
        controller.beginLiveUpdates()
    }

    func popoverDidClose(_ notification: Notification) {
        controller.endLiveUpdates()
    }
}
