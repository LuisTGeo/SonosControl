import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SonosController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        setUpHotKey()
        // Warm discovery in the background so the list is ready on first click.
        controller.refresh()
    }

    // MARK: - Setup

    private func setUpStatusItem() {
        // Match WindowList: compact icon-only item, with the popover anchored
        // directly below it in the menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "hifispeaker.2.fill",
                accessibilityDescription: "Sonos"
            )
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

    private func setUpHotKey() {
        // ⌘⌥S toggles the panel from anywhere.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.togglePopover()
        }
    }

    // MARK: - Popover control

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        controller.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Make the popover window key so it takes focus immediately (matters when
        // opened via the global hotkey while another app is frontmost).
        popover.contentViewController?.view.window?.makeKey()
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
