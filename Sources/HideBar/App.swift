import AppKit

@main
enum HideBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }

        let controller = MenuBarController()
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        self.controller = controller

        let prefs = Preferences.shared
        if !prefs.didShowWelcome {
            prefs.didShowWelcome = true
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// `hidebar://toggle`, `hidebar://show`, `hidebar://hide`, `hidebar://settings`,
    /// `hidebar://launch-at-login/on|off` for Shortcuts, Raycast etc.; `hidebar://debug` writes the separator
    /// geometry to the log.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "hidebar" {
            switch url.host {
            case "toggle": controller?.toggle()
            case "show": controller?.expand()
            case "hide": controller?.collapse()
            case "settings": showSettings()
            case "launch-at-login": try? LoginItem.setEnabled(url.lastPathComponent != "off")
            case "debug": controller?.logGeometry()
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }

    private func showSettings() {
        guard let controller else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(controller: controller)
        }
        settingsWindow?.show()
    }

    /// Only one copy may own the separator; a second launch just opens the running copy's settings.
    private func activateExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != me }) else { return false }
        if let url = other.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        return true
    }
}
