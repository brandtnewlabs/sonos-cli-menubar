import AppKit
import SwiftUI

@main
struct SonosBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // launchd starts the app as `SonosBar --run-autogroup` for the scheduled
        // auto-group. Intercept before any UI so a scheduled run stays headless.
        if CommandLine.arguments.contains("--run-autogroup") {
            AutoGroupRunner.runHeadlessAndExit()
        }
    }

    var body: some Scene {
        // The app is entirely status-item driven (see AppDelegate); this empty
        // scene exists only to satisfy the `App` protocol and shows no window.
        Settings { EmptyView() }
    }
}

/// A classic `NSStatusItem` + `NSPopover` menu-bar controller.
///
/// SwiftUI's `MenuBarExtra(.window)` has well-known focus/presentation quirks
/// from an accessory app — the icon highlights on click but the window never
/// appears. Driving the status item and popover directly with AppKit is the
/// reliable path, and still hosts the SwiftUI `MenuView` verbatim.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SonosStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient   // click outside to dismiss
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: MenuView().environmentObject(store))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "SonosBar")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Bring the popover forward so sliders and text fields take input.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
}
