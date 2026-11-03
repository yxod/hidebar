import AppKit
import SwiftUI

/// Settings in toolbar tabs, like System Settings panes. While the window is open the icons and the |
/// separator stay visible, so they can be ⌘-dragged.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Also the toolbar item identifiers of the tabs, which AppKit requires to be strings.
    enum Tab: String {
        case general, hiding, accessibility, updates, about
    }

    private let controller: MenuBarController
    private let tabs = NSTabViewController()

    init(controller: MenuBarController, updates: UpdateController) {
        self.controller = controller
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.item(.general, NSLocalizedString("General", comment: ""), "gearshape",
                                      GeneralTab(controller: controller)))
        tabs.addTabViewItem(Self.item(.hiding, NSLocalizedString("Hiding", comment: ""), "eye.slash",
                                      HidingTab(controller: controller)))
        if MenuBarController.usesAgentMenuBar {
            tabs.addTabViewItem(Self.item(.accessibility, NSLocalizedString("Accessibility", comment: ""),
                                          "hand.raised", AccessibilityTab()))
        }
        tabs.addTabViewItem(Self.item(.updates, NSLocalizedString("Updates", comment: ""),
                                      "arrow.triangle.2.circlepath", UpdatesTab(updates: updates)))
        tabs.addTabViewItem(Self.item(.about, NSLocalizedString("About", comment: ""), "info.circle",
                                      AboutTab(controller: controller, updates: updates)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(tab: Tab? = nil) {
        if let tab, let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == tab.rawValue }) {
            tabs.selectedTabViewItemIndex = index
        }
        controller.beginArranging()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller.endArranging()
    }

    private static func item(_ tab: Tab, _ title: String, _ symbol: String, _ content: some View) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.identifier = tab.rawValue
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}

/// Every tab is a grouped form as tall as its content, so the window fits each pane.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject private var prefs = Preferences.shared

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemNeedsApproval = LoginItem.needsApproval
    @State private var loginItemError: String?

    var body: some View {
        Pane {
            Section {
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
                Toggle("Hide icons on launch", isOn: $prefs.collapseOnLaunch)
                Picker("Language", selection: Binding(get: { AppLanguage.current },
                                                      set: { AppLanguage.switchTo($0) })) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.name).tag(language)
                    }
                }
                .help(Text("HideBar restarts to switch the language."))
            }

            Section {
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
            } footer: {
                Text("To come back here, open HideBar again from Spotlight or the Applications folder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refreshLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
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
    }
}

// MARK: - Hiding

private struct HidingTab: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject private var prefs = Preferences.shared

    private static let delays: [Double] = [3, 5, 10, 15, 30, 60]

    var body: some View {
        Pane {
            if controller.separatorInOverflow {
                Section {
                    Label("The | separator sits in the system overflow, so there is nothing to hide. Hold ⌘ and drag it to the right of the icons you want to hide, or press Reset Positions.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
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
        }
    }

    private func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Accessibility

private struct AccessibilityTab: View {
    @State private var trusted = MenuBarAccessibility.isTrusted

    var body: some View {
        Pane {
            Section {
                LabeledContent("Status") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not granted", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Text("Lets HideBar see exactly where every icon is, so hidden ones never slip back into the bar, and press » for you, so icons shown with « hide again on their own. Without it everything else works; close the row with » yourself.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if trusted {
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
            } footer: {
                Text("In System Settings › Privacy & Security, switch HideBar on. This window notices it right away.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The permission is usually switched on in System Settings while this window stays in the background.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            trusted = MenuBarAccessibility.isTrusted
        }
    }
}

// MARK: - Updates

private struct UpdatesTab: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Pane {
            Section {
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
        }
    }

    private var lastUpdateCheck: String {
        guard let date = updates.lastCheckDate else { return NSLocalizedString("Not checked yet", comment: "") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current.rawValue)
        return String(format: NSLocalizedString("Last checked: %@", comment: ""),
                      formatter.localizedString(for: date, relativeTo: Date()))
    }
}

// MARK: - About

private struct AboutTab: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var updates: UpdateController

    @State private var diagnosticsCopied = false

    var body: some View {
        Pane {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "HideBar")
                            .font(.title2.bold())
                        Text(Self.version)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://github.com/yxod/hidebar")!) {
                        Text(verbatim: "github.com/yxod/hidebar")
                    }
                }
            }

            Section {
                HowItWorks()
            }

            Section {
                LabeledContent("Hiding method", value: MenuBarController.usesAgentMenuBar
                    ? NSLocalizedString("System overflow «", comment: "")
                    : NSLocalizedString("Off-screen push", comment: ""))
                HStack {
                    Button(action: copyDiagnostics) {
                        Text(diagnosticsCopied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy Diagnostics"))
                    }
                    .help(Text("Copies versions, display and menu bar details and recent log lines for a bug report."))
                    Spacer()
                    Button("Quit HideBar") { NSApp.terminate(nil) }
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return String(format: NSLocalizedString("Version %@", comment: ""), "\(short) (\(build))")
    }

    private func copyDiagnostics() {
        Diagnostics.copyReport(controller: controller, updates: updates) {
            diagnosticsCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
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
