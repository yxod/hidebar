import AppKit
import SwiftUI

/// While the window is open the icons and the | separator stay visible, so they can be ⌘-dragged.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let controller: MenuBarController

    init(controller: MenuBarController, updates: UpdateController) {
        self.controller = controller
        let hosting = NSHostingController(rootView: SettingsView(controller: controller, updates: updates))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("HideBar Settings", comment: "")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        controller.beginArranging()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller.endArranging()
    }
}

struct SettingsView: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var updates: UpdateController
    @ObservedObject private var prefs = Preferences.shared

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemNeedsApproval = LoginItem.needsApproval
    @State private var loginItemError: String?
    @State private var accessibilityTrusted = MenuBarAccessibility.isTrusted

    private static let delays: [Double] = [3, 5, 10, 15, 30, 60]

    var body: some View {
        Form {
            Section {
                HowItWorks()
            }

            if controller.separatorInOverflow {
                Section {
                    Label("The | separator sits in the system overflow, so there is nothing to hide. Hold ⌘ and drag it to the right of the icons you want to hide, or press Reset Positions.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginItemNeedsApproval {
                    HStack {
                        Text("Allow HideBar in System Settings › Login Items.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open…") { LoginItem.openSystemSettings() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Picker("Language", selection: Binding(get: { AppLanguage.current },
                                                      set: { AppLanguage.switchTo($0) })) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.name).tag(language)
                    }
                }
                .help(Text("HideBar restarts to switch the language."))
                Toggle("Hide icons on launch", isOn: $prefs.collapseOnLaunch)
                LabeledContent("Show/hide shortcut") {
                    ShortcutRecorder(combo: $prefs.hotKey) { recording in
                        controller.setHotKeySuspended(recording)
                    }
                }
                if controller.hotKeyUnavailable {
                    Text("This shortcut is taken by another app. Choose a different one.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Hiding") {
                Toggle("Hide icons again automatically", isOn: $prefs.autoCollapse)
                Picker("After", selection: $prefs.autoCollapseDelay) {
                    ForEach(Self.delays, id: \.self) { delay in
                        Text(String(format: NSLocalizedString("%d sec", comment: ""), Int(delay))).tag(delay)
                    }
                }
                .disabled(!prefs.autoCollapse)
                Toggle("Wait while the pointer is in the menu bar", isOn: $prefs.holdWhilePointerInMenuBar)
                    .disabled(!prefs.autoCollapse)
                if !MenuBarController.usesAgentMenuBar {
                    Toggle("Show icons when the pointer rests on the arrow", isOn: $prefs.expandOnHover)
                }
            }

            if MenuBarController.usesAgentMenuBar {
                Section {
                    LabeledContent("Status") {
                        if accessibilityTrusted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not granted", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("Lets HideBar press » for you, so icons shown with « hide again on their own. Without it everything else works; close the row with » yourself.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        if accessibilityTrusted {
                            Button("Open Privacy Settings…") { MenuBarAccessibility.openSystemSettings() }
                        } else {
                            Button("Allow Access…") {
                                // Adds HideBar to the list, then shows the page with its switch.
                                MenuBarAccessibility.requestTrust()
                                MenuBarAccessibility.openSystemSettings()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    Text("Accessibility")
                } footer: {
                    Text("In System Settings › Privacy & Security, switch HideBar on. This window notices it right away.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The agent-drawn menu bar has the system « instead of a HideBar arrow.
            if !MenuBarController.usesAgentMenuBar {
                Section("Appearance") {
                    Picker("Arrow", selection: $prefs.iconStyle) {
                        ForEach(ToggleIconStyle.allCases) { style in
                            Label {
                                Text(style.title)
                            } icon: {
                                Image(systemName: style.symbols.collapsed)
                            }
                            .tag(style)
                        }
                    }
                    Toggle("Show the | separator while icons are visible", isOn: $prefs.showSeparator)
                }
            }

            Section {
                HStack {
                    Button("Reset Positions") { controller.resetPositions() }
                    Spacer()
                    Button("Menu Bar Settings…") { openMenuBarSettings() }
                }
            } header: {
                Text("Icon positions")
            } footer: {
                Text("Reset puts the separator next to the system icons. To remove an app's icon from the menu bar for good, switch it off in System Settings › Menu Bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Updates") {
                Toggle("Check for updates automatically",
                       isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically",
                       isOn: Binding(get: { updates.automaticallyDownloads },
                                     set: { updates.automaticallyDownloads = $0 }))
                    .disabled(!updates.automaticallyChecks)
                HStack {
                    Text(lastUpdateCheck)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }

            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Hiding method", value: MenuBarController.usesAgentMenuBar
                    ? NSLocalizedString("System overflow «", comment: "")
                    : NSLocalizedString("Off-screen push", comment: ""))
                HStack {
                    Spacer()
                    Button("Quit HideBar") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 560, idealHeight: 760)
        .onAppear(perform: refreshLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
        // The permission is usually switched on in System Settings while this window stays in the background.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            accessibilityTrusted = MenuBarAccessibility.isTrusted
        }
    }

    private var lastUpdateCheck: String {
        guard let date = updates.lastCheckDate else { return NSLocalizedString("Not checked yet", comment: "") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current.rawValue)
        return String(format: NSLocalizedString("Last checked: %@", comment: ""),
                      formatter.localizedString(for: date, relativeTo: Date()))
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LoginItem.isEnabled else { return }
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        launchAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
        loginItemNeedsApproval = LoginItem.needsApproval
        accessibilityTrusted = MenuBarAccessibility.isTrusted
    }

    private func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct HowItWorks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it works")
                .font(.headline)
            if MenuBarController.usesAgentMenuBar {
                row("chevron.left.2", "Icons left of the | separator are tucked behind the system « button. Click « to show them in place, click » to hide them again.")
                row("command", "While this window is open the | separator is visible: hold ⌘ and drag icons to either side of it.")
                row("keyboard", "The shortcut shows every icon in the bar; click | or wait a few seconds to hide them again.")
                row("bell.badge", "Clicking the clock keeps opening Notification Center: HideBar never switches on Assessment Mode.")
                row("gearshape", "To come back here, open HideBar again from Spotlight or the Applications folder.")
            } else {
                row("chevron.left", "Click the arrow to hide every icon left of the | separator. Click it again to bring them back.")
                row("command", "Hold ⌘ and drag icons in the menu bar to choose which ones hide: put them left of |.")
                row("bell.badge", "Clicking the clock keeps opening Notification Center: HideBar never switches on Assessment Mode.")
                row("cursorarrow.click.2", "Right-click the arrow for the menu, ⌥-click it for these settings.")
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
