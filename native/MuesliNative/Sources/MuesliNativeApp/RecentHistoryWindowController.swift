import AppKit
import Foundation
import SwiftUI
import MuesliCore

@MainActor
final class RecentHistoryWindowController: NSObject, NSWindowDelegate {
    private let store: DictationStore
    private let controller: MuesliController
    private var window: NSWindow?
    private var keyMonitor: Any?

    var presentationWindow: NSWindow? {
        window
    }

    init(store: DictationStore, controller: MuesliController) {
        self.store = store
        self.controller = controller
    }

    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        applyAppearance(to: window)
        controller.syncAppState()
        if !window.isVisible {
            controller.noteWindowOpened()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func reload() {
        if let window {
            applyAppearance(to: window)
        }
        controller.syncAppState()
    }

    /// The window is created before SwiftUI applies `preferredColorScheme`, and AppKit chrome
    /// (transparent titlebar, traffic lights, resize corners) resolves against the window's own
    /// appearance rather than the SwiftUI environment. Without this the titlebar keeps rendering
    /// dark while the app is set to the light theme.
    private func applyAppearance(to window: NSWindow) {
        let name: NSAppearance.Name = controller.appState.config.darkMode ? .darkAqua : .aqua
        if window.appearance?.name != name {
            window.appearance = NSAppearance(named: name)
        }
    }

    func close() {
        window?.close()
    }

    func updateBackendLabel() {
        controller.syncAppState()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        controller.noteWindowClosed()
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 140, width: 1120, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = MuesliTheme.backgroundDeepNSColor
        applyAppearance(to: window)

        let rootView = DashboardRootView(
            appState: controller.appState,
            controller: controller
        )
        window.contentView = NSHostingView(rootView: rootView)

        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "f" else {
                return event
            }
            self.controller.appState.focusSearchField = true
            return nil
        }
    }
}
