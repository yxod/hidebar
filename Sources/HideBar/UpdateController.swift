import AppKit
import Sparkle

/// Updates through Sparkle. The feed is the appcast.xml attached to the latest GitHub release (SUFeedURL in
/// Info.plist), and each update must carry an EdDSA signature matching SUPublicEDKey.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false

    private var standardController: SPUStandardUpdaterController!
    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        standardController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: self)
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = canCheck }
        }
    }

    private var updater: SPUUpdater { standardController.updater }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        NSApp.activate()
        standardController.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// A menu bar app has no Dock icon for Sparkle to badge, so it shows scheduled updates as gentle reminders.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update found in the background would otherwise sit behind other apps' windows.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        DispatchQueue.main.async { NSApp.activate() }
    }
}
