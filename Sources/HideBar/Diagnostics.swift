import AppKit
import OSLog

/// A plain-text report for bug reports: versions, displays, settings, menu bar geometry and HideBar's recent
/// log. It holds positions of menu bar items but not which apps they belong to.
enum Diagnostics {
    /// Builds the report and copies it; reading the system log can take a moment, so that runs off the main
    /// thread and `completion` follows once the report is on the pasteboard.
    @MainActor
    static func copyReport(controller: MenuBarController, updates: UpdateController,
                           completion: @escaping @MainActor () -> Void) {
        let summary = report(controller: controller, updates: updates)
        DispatchQueue.global(qos: .userInitiated).async {
            let log = (["Recent log:"] + recentLog()).joined(separator: "\n")
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary + "\n" + log, forType: .string)
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    @MainActor
    private static func report(controller: MenuBarController, updates: UpdateController) -> String {
        let info = Bundle.main.infoDictionary
        let prefs = Preferences.shared
        var lines = [
            "HideBar \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(hardwareModel)",
            "Language: \(AppLanguage.current.rawValue)",
            "Hiding method: \(MenuBarController.usesAgentMenuBar ? "system overflow" : "off-screen push")",
            "Accessibility: \(MenuBarAccessibility.isTrusted ? "granted" : "not granted")",
            "Launch at login: \(LoginItem.isEnabled ? "on" : LoginItem.needsApproval ? "needs approval" : "off")",
            "Settings: hide on launch \(prefs.collapseOnLaunch), auto-hide \(prefs.autoCollapse) after \(Int(prefs.autoCollapseDelay)) s, "
                + "wait for pointer \(prefs.holdWhilePointerInMenuBar), shortcut \(prefs.hotKey?.displayString ?? "none")",
            "Updates: check \(updates.automaticallyChecks), install \(updates.automaticallyDownloads), "
                + "last check \(updates.lastCheckDate.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
        ]
        for screen in NSScreen.screens {
            let frame = screen.frame
            lines.append("Display \(screen.localizedName): \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) "
                + "@\(Int(screen.backingScaleFactor))x, notch edge \(screen.notchRightEdge.map { "\(Int($0))" } ?? "none")")
        }
        lines += controller.diagnosticLines()
        return lines.joined(separator: "\n")
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// The last entries HideBar wrote to the system log in this run.
    private nonisolated static func recentLog(limit: Int = 40) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", "dev.qweb.HideBar"))
        else { return ["(unavailable)"] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
        return Array(lines.suffix(limit))
    }
}
