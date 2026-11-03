import Foundation
import Combine

enum ToggleIconStyle: String, CaseIterable, Identifiable {
    case chevron
    case triangle
    case dot
    case eye

    var id: String { rawValue }

    /// SF Symbol shown while icons are hidden and while they are visible.
    var symbols: (collapsed: String, expanded: String) {
        switch self {
        case .chevron: ("chevron.left", "chevron.right")
        case .triangle: ("arrowtriangle.left.fill", "arrowtriangle.right.fill")
        case .dot: ("circle.fill", "circle")
        case .eye: ("eye.slash", "eye")
        }
    }

    var title: String {
        switch self {
        case .chevron: NSLocalizedString("Chevron", comment: "")
        case .triangle: NSLocalizedString("Triangle", comment: "")
        case .dot: NSLocalizedString("Dot", comment: "")
        case .eye: NSLocalizedString("Eye", comment: "")
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let collapseOnLaunch = "collapseOnLaunch"
        static let autoCollapse = "autoCollapse"
        static let autoCollapseDelay = "autoCollapseDelay"
        static let holdWhilePointerInMenuBar = "holdWhilePointerInMenuBar"
        static let expandOnHover = "expandOnHover"
        static let iconStyle = "iconStyle"
        static let showSeparator = "showSeparator"
        static let hotKey = "hotKey"
        static let didShowWelcome = "didShowWelcome"
    }

    private let defaults = UserDefaults.standard

    @Published var collapseOnLaunch: Bool { didSet { defaults.set(collapseOnLaunch, forKey: Key.collapseOnLaunch) } }
    @Published var autoCollapse: Bool { didSet { defaults.set(autoCollapse, forKey: Key.autoCollapse) } }
    @Published var autoCollapseDelay: Double { didSet { defaults.set(autoCollapseDelay, forKey: Key.autoCollapseDelay) } }
    @Published var holdWhilePointerInMenuBar: Bool { didSet { defaults.set(holdWhilePointerInMenuBar, forKey: Key.holdWhilePointerInMenuBar) } }
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: Key.expandOnHover) } }
    @Published var iconStyle: ToggleIconStyle { didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) } }
    @Published var showSeparator: Bool { didSet { defaults.set(showSeparator, forKey: Key.showSeparator) } }
    @Published var hotKey: KeyCombo? {
        didSet {
            if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: Key.hotKey)
            } else {
                defaults.removeObject(forKey: Key.hotKey)
            }
        }
    }

    var didShowWelcome: Bool {
        get { defaults.bool(forKey: Key.didShowWelcome) }
        set { defaults.set(newValue, forKey: Key.didShowWelcome) }
    }

    private init() {
        defaults.register(defaults: [
            Key.collapseOnLaunch: true,
            Key.autoCollapse: true,
            Key.autoCollapseDelay: 10.0,
            Key.holdWhilePointerInMenuBar: true,
            Key.expandOnHover: false,
            Key.iconStyle: ToggleIconStyle.chevron.rawValue,
            Key.showSeparator: true,
        ])
        collapseOnLaunch = defaults.bool(forKey: Key.collapseOnLaunch)
        autoCollapse = defaults.bool(forKey: Key.autoCollapse)
        autoCollapseDelay = defaults.double(forKey: Key.autoCollapseDelay)
        holdWhilePointerInMenuBar = defaults.bool(forKey: Key.holdWhilePointerInMenuBar)
        expandOnHover = defaults.bool(forKey: Key.expandOnHover)
        iconStyle = ToggleIconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .chevron
        showSeparator = defaults.bool(forKey: Key.showSeparator)
        hotKey = defaults.data(forKey: Key.hotKey).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
    }
}
