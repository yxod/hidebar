import AppKit

/// The interface language, chosen in the app rather than following the system; English unless switched.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case ukrainian = "uk"

    private static let defaultsKey = "appLanguage"

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whatever the current one is.
    var name: String {
        switch self {
        case .english: "English"
        case .ukrainian: "Українська"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .english
    }

    /// Bundle picks its localization from AppleLanguages the first time it localizes anything, so this has to
    /// run before the app starts.
    static func applyAtLaunch() {
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }

    /// Takes effect on the next launch, so HideBar restarts and reopens the settings window.
    static func switchTo(_ language: AppLanguage) {
        guard language != current else { return }
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")

        // The new copy starts once this one is gone; otherwise it would hand over to it and quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\" --args \(AppDelegate.showSettingsArgument)",
                              Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
