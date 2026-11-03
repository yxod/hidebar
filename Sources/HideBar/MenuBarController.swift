import AppKit
import Combine
import os

private let logger = Logger(subsystem: "dev.qweb.HideBar", category: "layout")

/// Layout tracing; read it with `log show --last 5m --predicate 'subsystem == "dev.qweb.HideBar"'`.
private func trace(_ message: @autoclosure () -> String) {
    let text = message()
    logger.notice("\(text, privacy: .public)")
}

/// Hides menu bar icons by widening an empty "separator" status item.
///
/// Everything left of the separator is pushed out of the visible menu bar:
/// - With the agent-drawn menu bar (`com.apple.MenuBarAgent`, macOS 27) an item that is too wide is moved
///   into the system overflow instead of pushing its neighbours off-screen. So the separator is sized to
///   fill exactly the free space, and the icons left of it land in the system overflow behind the « button.
///   HideBar adds no arrow of its own: clicking « shows the hidden icons in place, clicking » hides them.
/// - On older systems the classic 10 000 pt trick pushes them past the screen edge, and a HideBar arrow
///   toggles them.
///
/// The menu bar doesn't say whether its overflow row is open, so an invisible "row sensor" item reports it:
/// it sits left of everything, always in the overflow, and its window's occlusion state turns visible
/// exactly while the overflow row is open. That needs no permission.
///
/// Hidden Bar 1.11 hides icons with an Assessment Mode assertion instead, and Assessment Mode is what stops
/// Notification Center from opening on a click on the clock. Nothing here touches that API.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    private enum ItemName {
        static let toggle = "HideBarToggle"
        static let separator = "HideBarSeparator"
        static let rowSensor = "HideBarRowSensor"
    }

    private enum Metrics {
        static let expandedSeparatorLength: CGFloat = 12
        static let hiddenSeparatorLength: CGFloat = 1
        static let sensorLength: CGFloat = 1
        static let legacyCollapsedLength: CGFloat = 10_000
        /// Free room left next to the notch, measured on macOS 27. With too little room for the system « the
        /// menu bar draws it over the separator's right end, right next to the visible icons. While the overflow
        /// row is open the » needs its own slot, or the separator gets thrown into the row.
        static let chevronOverlapReserve: CGFloat = 40
        static let chevronSlotReserve: CGFloat = 64
        /// Shrink step when the separator doesn't fit, e.g. next to the screen-recording pill.
        static let shrinkStep: CGFloat = 24
        /// The menu bar pads every item by this much in total.
        static let itemPadding: CGFloat = 16
        static let minimumCollapsedLength: CGFloat = 20
        /// How far the separator's right edge may drift while it is being resized.
        static let anchorTolerance: CGFloat = 24
        /// Preferred positions are distances from the right screen edge; these land just left of the
        /// system items (battery, Wi-Fi, Control Center) on a fresh install.
        static let defaultTogglePosition: Double = 360
        static let defaultSeparatorPosition: Double = 380
        /// Left of any real item, so the row sensor is the first to overflow.
        static let rowSensorPosition: Double = 9_999
    }

    static let usesAgentMenuBar = !NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").isEmpty

    @Published private(set) var isCollapsed = false
    /// The separator itself landed in the system overflow, so there is no free space it could fill.
    @Published private(set) var separatorInOverflow = false
    @Published private(set) var hotKeyUnavailable = false

    var onOpenSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    private let prefs = Preferences.shared
    /// Only on the classic menu bar; the agent-drawn one has the system « for this.
    private var toggleItem: NSStatusItem?
    private var separatorItem: NSStatusItem!
    private var rowSensor: NSStatusItem?

    /// While arranging (the settings window is open) the icons stay visible.
    private var isArranging = false
    /// Expanded because the overflow row was opened with «; closing it with » hides the icons again.
    private var isRevealing = false
    private var lastRowOpen = false
    private var sensorCheckScheduled = false

    /// The separator's right edge while expanded; it stays put while the separator grows to the left.
    private var anchorMaxX: CGFloat?
    private var fitTask: Task<Void, Never>?
    /// When fitting last gave up because nothing fit; retrying on every relayout would just make icons flicker.
    private var fitGaveUpAt: Date?
    /// Icons left of the separator that growing over them couldn't push out (a system indicator, say), by
    /// position; the same set isn't retried, a changed one is.
    private var blockedLeaks: [Int]?
    /// Fitted lengths for displays without a notch, where the free width depends on the active app's menus.
    private var fitCache: [String: CGFloat] = [:]

    private var expandedByHover = false
    private var autoCollapseTimer: Timer?
    private var hoverTimer: Timer?
    private var watchdogTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var hotKey: GlobalHotKey?
    private var registeredCombo: KeyCombo?
    private var hotKeySuspended = false
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        createItems()
        observeSystem()
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.preferencesChanged() }
            .store(in: &cancellables)
        preferencesChanged()

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog() }
        }

        if prefs.collapseOnLaunch {
            // Give the menu bar a moment to place the new items before measuring them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                // The first-run settings window may already have started arranging.
                guard let self, !self.isArranging else { return }
                self.collapse()
            }
        }
    }

    // MARK: - Public actions

    func toggle() {
        isCollapsed ? expand() : collapse()
    }

    func collapse() {
        guard !isCollapsed else { return }
        if isOverflowRowOpen {
            // Collapsing can't close the system overflow row, and with it open the hidden icons would jump
            // into it on the far left. Keep them in place; closing the row with » collapses.
            trace("collapse deferred until the overflow row closes")
            isRevealing = true
            isArranging = false
            updateAppearance()
            scheduleAutoCollapse()
            return
        }
        isRevealing = false
        cancelAutoCollapse()
        cancelHover()
        expandedByHover = false
        isCollapsed = true
        updateAppearance()
        if Self.usesAgentMenuBar {
            trace("collapse: separator=\(String(describing: separatorItem.button?.window?.frame)) rowOpen=\(isOverflowRowOpen)")
            if let frame = laidOutSeparatorFrame() {
                anchorMaxX = frame.maxX
                startFit()
            } else {
                remeasureAndFit()
            }
        } else {
            separatorItem.length = Metrics.legacyCollapsedLength
        }
    }

    func expand(byHover: Bool = false) {
        guard isCollapsed else { return }
        fitTask?.cancel()
        fitTask = nil
        isCollapsed = false
        expandedByHover = byHover
        trace("expand byHover=\(byHover) revealing=\(isRevealing)")
        separatorItem.length = expandedSeparatorLength
        updateAppearance()
        scheduleAutoCollapse()
    }

    /// Shows the icons and the | separator until `endArranging`, so they can be ⌘-dragged around it.
    func beginArranging() {
        isArranging = true
        isRevealing = false
        expand()
        updateAppearance()
        separatorItem.length = expandedSeparatorLength
        cancelAutoCollapse()
    }

    func endArranging() {
        guard isArranging else { return }
        isArranging = false
        collapse()
    }

    /// Puts the items back to their default spots, e.g. after they ended up in the overflow.
    func resetPositions() {
        let wasCollapsed = isCollapsed
        expand()
        for item in [toggleItem, separatorItem, rowSensor].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        let defaults = UserDefaults.standard
        for name in [ItemName.toggle, ItemName.separator] {
            defaults.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
            defaults.removeObject(forKey: "NSStatusItem Visible \(name)")
        }
        createItems()
        if wasCollapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.collapse() }
        }
    }

    /// The shortcut recorder turns the live shortcut off so pressing it doesn't toggle the bar.
    func setHotKeySuspended(_ suspended: Bool) {
        hotKeySuspended = suspended
        updateHotKey()
    }

    func logGeometry() {
        trace("geometry: separator=\(String(describing: separatorItem.button?.window?.frame)) length=\(separatorItem.length) rowSensor=\(Self.describe(rowSensor)) notch=\(String(describing: separatorScreen?.notchRightEdge))")
        guard let screen = separatorScreen else { return }
        if let snapshot = MenuBarAccessibility.snapshot(on: screen) {
            let items = snapshot.items.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))\($0.identifier.isEmpty ? "" : ":" + $0.identifier)" }
            trace("accessibility: overflowButton=\(String(describing: snapshot.overflowButton)) items=\(items.joined(separator: " "))")
        } else {
            trace("accessibility: no snapshot (not trusted?)")
        }
        if let edge = layoutEdge(on: screen) {
            trace("edge=\(edge) leaks=\(String(describing: iconsLeftOfSeparator(on: screen, edge: edge)?.map { Int($0.minX) }))")
        }
    }


    func prepareForTermination() {
        fitTask?.cancel()
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }

    // MARK: - Items

    private func createItems() {
        Self.seedDefaultPositions()

        separatorItem = NSStatusBar.system.statusItem(withLength: expandedSeparatorLength)
        separatorItem.autosaveName = ItemName.separator
        separatorItem.isVisible = true
        if let button = separatorItem.button {
            button.target = self
            button.action = #selector(separatorClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier(MenuBarAccessibility.identifierPrefix + "separator")
        }

        if Self.usesAgentMenuBar {
            rowSensor = Self.makeSensor(ItemName.rowSensor, position: Metrics.rowSensorPosition)
        } else {
            let toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            toggleItem.autosaveName = ItemName.toggle
            toggleItem.isVisible = true
            if let button = toggleItem.button {
                button.target = self
                button.action = #selector(toggleClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            self.toggleItem = toggleItem
        }

        updateAppearance()
    }

    private static func makeSensor(_ name: String, position: Double) -> NSStatusItem {
        UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position \(name)")
        let item = NSStatusBar.system.statusItem(withLength: Metrics.sensorLength)
        item.autosaveName = name
        item.isVisible = true
        item.button?.setAccessibilityIdentifier(MenuBarAccessibility.identifierPrefix + name)
        // An empty button means nothing to VoiceOver users.
        item.button?.setAccessibilityElement(false)
        return item
    }

    private static func seedDefaultPositions() {
        let defaults = UserDefaults.standard
        let seeds = [(ItemName.toggle, Metrics.defaultTogglePosition),
                     (ItemName.separator, Metrics.defaultSeparatorPosition)]
        for (name, position) in seeds {
            let key = "NSStatusItem Preferred Position \(name)"
            if defaults.object(forKey: key) == nil {
                defaults.set(position, forKey: key)
            }
        }
    }

    /// On the agent-drawn menu bar the | is the only thing HideBar shows, so it can't be switched off; it also
    /// marks, while revealing, which icons the » will hide again.
    private var showsSeparatorWhenExpanded: Bool {
        Self.usesAgentMenuBar || prefs.showSeparator
    }

    private var expandedSeparatorLength: CGFloat {
        showsSeparatorWhenExpanded ? Metrics.expandedSeparatorLength : Metrics.hiddenSeparatorLength
    }

    private func updateAppearance() {
        let symbols = prefs.iconStyle.symbols
        let symbolName = isCollapsed ? symbols.collapsed : symbols.expanded
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        image?.isTemplate = true

        if let button = toggleItem?.button {
            button.image = image
            let label = isCollapsed
                ? NSLocalizedString("Show hidden icons", comment: "")
                : NSLocalizedString("Hide icons", comment: "")
            button.setAccessibilityLabel(label)
            button.toolTip = label + "\n" + NSLocalizedString("Right-click for menu, ⌥-click for settings", comment: "")
        }

        if let button = separatorItem.button {
            button.image = (isCollapsed || !showsSeparatorWhenExpanded) ? nil : Self.separatorImage
            button.setAccessibilityLabel(NSLocalizedString("HideBar separator", comment: ""))
            button.toolTip = isCollapsed ? nil : NSLocalizedString("Click to hide icons left of |, right-click for menu", comment: "")
        }
    }

    private static let separatorImage: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 2, height: 14), xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    // MARK: - Clicks and menu

    @objc private func toggleClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu(on: sender)
        } else if event?.modifierFlags.contains(.option) == true {
            onOpenSettings?()
        } else {
            toggle()
        }
    }

    @objc private func separatorClicked(_ sender: NSStatusBarButton) {
        // Collapsed, the separator is an invisible gap with the system « drawn over its end; a click that
        // reaches it was meant for the «.
        guard !isCollapsed else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu(on: sender)
        } else if !isOverflowRowOpen {
            // With the overflow row open, collapsing couldn't close it and the hidden icons would jump into
            // it on the far left; the » hides them properly.
            isArranging = false
            toggle()
        }
    }

    private func showMenu(on button: NSStatusBarButton) {
        guard let item = [toggleItem, separatorItem].compactMap({ $0 }).first(where: { $0.button === button })
        else { return }
        let menu = NSMenu()
        let toggleTitle = isCollapsed
            ? NSLocalizedString("Show hidden icons", comment: "")
            : NSLocalizedString("Hide icons", comment: "")
        menu.addItem(withTitle: toggleTitle, action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Settings…", comment: ""), action: #selector(menuSettings),
                     keyEquivalent: ",").target = self
        menu.addItem(withTitle: NSLocalizedString("Check for Updates…", comment: ""),
                     action: #selector(menuCheckForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Quit HideBar", comment: ""),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuSettings() { onOpenSettings?() }
    @objc private func menuCheckForUpdates() { onCheckForUpdates?() }

    // MARK: - Sensors

    /// The overflow row is open: the row sensor, which always sits in the overflow, is on screen left of
    /// the notch. Only meaningful with a notch, where the row's place is known.
    private var isOverflowRowOpen: Bool {
        guard let window = rowSensor?.button?.window, let notchEdge = separatorScreen?.notchRightEdge else {
            return false
        }
        return window.occlusionState.contains(.visible) && window.frame.maxX <= notchEdge + 1
    }

    private static func describe(_ item: NSStatusItem?) -> String {
        guard let window = item?.button?.window else { return "nil" }
        return "\(window.frame.origin.x)/\(window.occlusionState.contains(.visible) ? "visible" : "hidden")"
    }

    /// The row sensor's occlusion tells about the overflow row; the separator moving away tells it was
    /// pushed out of the bar (by a system indicator such as the screen-recording pill, say).
    private func observeSensors() {
        let center = NotificationCenter.default
        Publishers.Merge(center.publisher(for: NSWindow.didChangeOcclusionStateNotification),
                         center.publisher(for: NSWindow.didMoveNotification))
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow,
                      window === self.rowSensor?.button?.window || window === self.separatorItem.button?.window
                else { return }
                self.scheduleSensorCheck()
            }
            .store(in: &cancellables)
    }

    /// Occlusion changes arrive in bursts while the menu bar relays out; act once things settle.
    private func scheduleSensorCheck() {
        guard !sensorCheckScheduled else { return }
        sensorCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.sensorCheckScheduled = false
            self.sensorsChanged()
        }
    }

    private func sensorsChanged() {
        guard Self.usesAgentMenuBar else { return }
        if separatorScreen?.notchRightEdge != nil {
            let rowOpen = isOverflowRowOpen
            if rowOpen != lastRowOpen {
                lastRowOpen = rowOpen
                overflowRowChanged(open: rowOpen)
                return
            }
        }
        guard isCollapsed, fitTask == nil else { return }
        if let fitGaveUpAt, Date().timeIntervalSince(fitGaveUpAt) < 30 { return }
        guard let frame = laidOutSeparatorFrame() else {
            trace("separator left the bar, frame=\(String(describing: self.separatorItem.button?.window?.frame)) rowOpen=\(self.isOverflowRowOpen)")
            startFit()
            return
        }
        if let anchor = anchorMaxX, abs(frame.maxX - anchor) > Metrics.anchorTolerance {
            // Icons right of the separator came or went, so the free room changed with them. The collapsed
            // separator's edge sits a few points off the true anchor, so measure it properly.
            trace("separator moved: anchor \(anchor) -> \(frame.maxX)")
            remeasureAndFit()
            return
        }
        // With Accessibility the actual layout shows hidden icons that slipped back into the bar, for example
        // when a screen-recording indicator went away and freed its room.
        if !isOverflowRowOpen, let screen = separatorScreen, let edge = layoutEdge(on: screen),
           let leaks = iconsLeftOfSeparator(on: screen, edge: edge), !leaks.isEmpty {
            let positions = leaks.map { Int($0.minX) }
            guard positions != blockedLeaks else { return }
            trace("hidden icons slipped into the bar at \(positions)")
            startFit()
        }
    }

    private func overflowRowChanged(open: Bool) {
        trace("overflow row \(open ? "opened" : "closed"), collapsed=\(isCollapsed) revealing=\(isRevealing)")
        if open {
            cancelAutoCollapse()
            if isCollapsed, !isArranging {
                // The system shows hidden icons in a row on the far left, after the app's menus. Expanding
                // puts back in place the ones that fit right of the notch; the rest line up left of it.
                isRevealing = true
                expand()
            }
        } else if isRevealing {
            collapse()
        } else if isCollapsed {
            // The » had its own slot; take that room back so the « sits next to the icons again.
            startFit()
        } else {
            scheduleAutoCollapse()
        }
    }

    // MARK: - Fitting the separator (agent-drawn menu bar)

    private func startFit() {
        runFitTask { [weak self] in await self?.fitSeparator() }
    }

    /// Measures the anchor at the expanded length, then fits. Icons flash for a moment, so this only runs
    /// when the displays changed or the separator can't be fitted from what is known.
    private func remeasureAndFit() {
        runFitTask { [weak self] in
            guard let self else { return }
            self.separatorItem.length = self.expandedSeparatorLength
            guard await self.waitForLayout(), self.isCollapsed else { return }
            self.anchorMaxX = self.laidOutSeparatorFrame()?.maxX
            trace("remeasure: anchor=\(String(describing: self.anchorMaxX))")
            await self.fitSeparator(remeasured: true)
        }
    }

    private func runFitTask(_ body: @escaping @MainActor () async -> Void) {
        fitTask?.cancel()
        fitTask = Task { [weak self] in
            await body()
            // A cancelled task was replaced (or the bar expanded); leave the newer handle alone.
            guard !Task.isCancelled else { return }
            self?.fitTask = nil
        }
    }

    private func fitSeparator(remeasured: Bool = false) async {
        guard isCollapsed else { return }
        guard let anchor = anchorMaxX, let screen = separatorScreen else {
            separatorInOverflow = true
            separatorItem.length = expandedSeparatorLength
            return
        }
        separatorInOverflow = false

        guard let edge = layoutEdge(on: screen) else {
            await bisectSeparator(anchor: anchor, screen: screen)
            return
        }

        // Right of the notch (or of the active app's menus) the free width is almost known up front. Almost:
        // system indicators such as the screen-recording pill take room too, so verify and adjust.
        let rowOpen = isOverflowRowOpen
        var length = anchor - edge - (rowOpen ? Metrics.chevronSlotReserve : Metrics.chevronOverlapReserve)
        var fits = false
        while length >= Metrics.minimumCollapsedLength {
            guard let ok = await tryLength(length, anchor: anchor, screen: screen) else { return }
            trace("fit edge=\(edge) anchor=\(anchor) rowOpen=\(rowOpen) length=\(length) fits=\(ok)")
            if ok { fits = true; break }
            length -= Metrics.shrinkStep
        }
        fitGaveUpAt = nil
        guard fits else {
            if remeasured {
                trace("fit gave up")
                fitGaveUpAt = Date()
                separatorItem.length = Metrics.minimumCollapsedLength
            } else {
                // Nothing fits around the old anchor: icons right of the separator came or went.
                remeasureAndFit()
            }
            return
        }
        await coverLeakedIcons(from: length, anchor: anchor, screen: screen, edge: edge)
    }

    /// Where the room for status items begins: the notch, or without one the end of the active app's menus,
    /// which only Accessibility can tell.
    private func layoutEdge(on screen: NSScreen) -> CGFloat? {
        screen.notchRightEdge ?? MenuBarAccessibility.appMenusMaxX(on: screen)
    }

    /// Icons the menu bar shows between `edge` and the collapsed separator: hidden ones that slipped back, or
    /// a system indicator. Needs Accessibility; nil without it.
    private func iconsLeftOfSeparator(on screen: NSScreen, edge: CGFloat) -> [CGRect]? {
        guard let separator = laidOutSeparatorFrame(on: screen),
              let snapshot = MenuBarAccessibility.snapshot(on: screen) else { return nil }
        return snapshot.items.compactMap { item in
            let frame = item.frame
            // HideBar's own items, and empty slots narrower than any real icon.
            guard !item.identifier.hasPrefix(MenuBarAccessibility.identifierPrefix), frame.width >= 20,
                  frame.minX >= edge - 1, frame.maxX <= separator.minX + 2 else { return nil }
            // Overflowed items are parked behind the « button.
            if let button = snapshot.overflowButton, abs(frame.midX - button.midX) < 20 { return nil }
            return frame
        }
    }

    /// Grows the separator over hidden icons that slipped back into the bar, as long as it still fits.
    private func coverLeakedIcons(from length: CGFloat, anchor: CGFloat, screen: NSScreen, edge: CGFloat) async {
        var length = length
        for _ in 0..<3 {
            guard let separator = laidOutSeparatorFrame(on: screen),
                  let leaks = iconsLeftOfSeparator(on: screen, edge: edge), !leaks.isEmpty,
                  let leftmost = leaks.map(\.minX).min() else {
                blockedLeaks = nil
                return
            }
            let wider = length + separator.minX - leftmost
            guard let fits = await tryLength(wider, anchor: anchor, screen: screen) else { return }
            trace("fit cover icons at \(leaks.map { Int($0.minX) }) length=\(wider) fits=\(fits)")
            if fits {
                length = wider
                continue
            }
            // Something there can't be pushed out, a system indicator say: stay at the widest that fits.
            guard await tryLength(length, anchor: anchor, screen: screen) != nil else { return }
            blockedLeaks = iconsLeftOfSeparator(on: screen, edge: edge)?.map { Int($0.minX) }
            return
        }
    }

    /// Without a notch the status items share the bar with the active app's menus, so the free width is
    /// only known by trying: bisect for the widest separator the menu bar still keeps in place.
    private func bisectSeparator(anchor: CGFloat, screen: NSScreen) async {
        let cacheKey = fitCacheKey(for: screen)
        var low = Metrics.minimumCollapsedLength
        var high = anchor - screen.frame.minX - Metrics.itemPadding
        if let cached = fitCache[cacheKey], cached > low, cached < high {
            guard let fits = await tryLength(cached, anchor: anchor, screen: screen) else { return }
            if fits { low = cached } else { high = cached }
            if fits, let widerFits = await tryLength(cached + 12, anchor: anchor, screen: screen) {
                if !widerFits { high = cached + 12 } else { low = cached + 12 }
            }
        }
        while high - low > 12 {
            let mid = ((low + high) / 2).rounded()
            guard let fits = await tryLength(mid, anchor: anchor, screen: screen) else { return }
            if fits { low = mid } else { high = mid }
        }
        guard await tryLength(low, anchor: anchor, screen: screen) != nil else { return }
        trace("fit bisect anchor=\(anchor) length=\(low)")
        fitCache[cacheKey] = low
    }

    /// Applies a length and reports whether the separator stayed in place; nil if the fit was abandoned.
    private func tryLength(_ length: CGFloat, anchor: CGFloat, screen: NSScreen) async -> Bool? {
        separatorItem.length = length
        guard await waitForLayout(), isCollapsed else { return nil }
        return isSeparatorFitted(anchor: anchor, screen: screen)
    }

    /// Waits until the menu bar has laid the items out again after a length change.
    private func waitForLayout() async -> Bool {
        try? await Task.sleep(for: .milliseconds(150))
        var last = separatorItem.button?.window?.frame
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
            let current = separatorItem.button?.window?.frame
            if current == last { break }
            last = current
        }
        return !Task.isCancelled
    }

    private func isSeparatorFitted(anchor: CGFloat, screen: NSScreen) -> Bool {
        guard let frame = laidOutSeparatorFrame(on: screen) else { return false }
        return abs(frame.maxX - anchor) <= Metrics.anchorTolerance
    }

    /// The separator's frame if the menu bar shows it in the bar itself rather than in the overflow.
    private func laidOutSeparatorFrame(on screen: NSScreen? = nil) -> NSRect? {
        guard let window = separatorItem.button?.window,
              let screen = screen ?? window.screen ?? NSScreen.main else { return nil }
        return Self.laidOut(window.frame, length: separatorItem.length, on: screen)
    }

    private static func laidOut(_ frame: NSRect, length: CGFloat, on screen: NSScreen) -> NSRect? {
        // An overflowed item reports a frame outside the bar, often clamped to a different width.
        guard frame.width > 0, frame.width <= length + 40,
              frame.minX >= screen.frame.minX - 1, frame.maxX <= screen.frame.maxX + 1 else { return nil }
        if let notchEdge = screen.notchRightEdge, frame.minX < notchEdge - 1 { return nil }
        return frame
    }

    private var separatorScreen: NSScreen? {
        separatorItem.button?.window?.screen ?? NSScreen.main
    }

    private func fitCacheKey(for screen: NSScreen) -> String {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
        return "\(screen.localizedName)|\(Int(screen.frame.width))|\(app)"
    }

    // MARK: - Watching the layout

    private func observeSystem() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.displaysChanged() }
            .store(in: &cancellables)

        // Without a notch the free width changes with the active app's menus.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isCollapsed, Self.usesAgentMenuBar,
                      self.separatorScreen?.notchRightEdge == nil else { return }
                self.startFit()
            }
            .store(in: &cancellables)

        if Self.usesAgentMenuBar { observeSensors() }
    }

    private func displaysChanged() {
        fitCache.removeAll()
        guard isCollapsed, Self.usesAgentMenuBar else { return }
        remeasureAndFit()
    }

    /// Runs every couple of seconds as a backstop for the notifications: refreshes the diagnostics and
    /// refits when the separator got pushed out of the bar.
    private func watchdog() {
        guard Self.usesAgentMenuBar, fitTask == nil else { return }
        sensorsChanged()
        if !isCollapsed, fitTask == nil {
            separatorInOverflow = laidOutSeparatorFrame() == nil
        }
    }

    // MARK: - Auto-collapse and hover

    private func scheduleAutoCollapse(after delay: TimeInterval? = nil) {
        cancelAutoCollapse()
        guard !isCollapsed, !isArranging else { return }
        // With the overflow row open, collapsing would throw the hidden icons into it on the far left. Only
        // icons revealed with « get hidden again, by pressing » for the user, which takes Accessibility.
        if isOverflowRowOpen, !(isRevealing && MenuBarAccessibility.isTrusted) { return }
        let interval: TimeInterval
        if expandedByHover {
            interval = delay ?? 1.0
        } else {
            guard prefs.autoCollapse else { return }
            interval = delay ?? prefs.autoCollapseDelay
        }
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoCollapseFired() }
        }
    }

    private func cancelAutoCollapse() {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
    }

    private func autoCollapseFired() {
        guard !isCollapsed else { return }
        let holdForPointer = (prefs.holdWhilePointerInMenuBar || expandedByHover) && Self.isPointerInMenuBar()
        if holdForPointer || Self.isMenuOpen() {
            scheduleAutoCollapse(after: expandedByHover ? 0.75 : 1.5)
            return
        }
        if isOverflowRowOpen {
            // Closing the row collapses through the row sensor, like a click on » would.
            guard isRevealing, MenuBarAccessibility.closeOverflowRow(on: separatorScreen) else { return }
            trace("auto-hide: pressed »")
            return
        }
        collapse()
    }

    private func updateMouseMonitoring() {
        let wanted = prefs.expandOnHover && toggleItem != nil
        guard wanted != !mouseMonitors.isEmpty else { return }
        if wanted {
            let handler: (NSEvent) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
                mouseMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
                handler(event)
                return event
            }) {
                mouseMonitors.append(local)
            }
        } else {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors.removeAll()
            cancelHover()
        }
    }

    private func mouseMoved() {
        guard isCollapsed, prefs.expandOnHover else { return }
        if hoverZoneContains(NSEvent.mouseLocation) {
            guard hoverTimer == nil else { return }
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverTimer = nil
                    if self.isCollapsed, self.hoverZoneContains(NSEvent.mouseLocation) {
                        self.expand(byHover: true)
                    }
                }
            }
        } else {
            cancelHover()
        }
    }

    private func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// The arrow plus the empty gap the collapsed separator leaves.
    private func hoverZoneContains(_ point: NSPoint) -> Bool {
        let frames = [toggleItem?.button?.window?.frame, separatorItem.button?.window?.frame].compactMap { $0 }
        return frames.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private static func isPointerInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            return false
        }
        let barHeight = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        return point.y >= screen.frame.maxY - barHeight - 2
    }

    /// A menu or a status-item popover is on screen; collapsing now would yank its icon away.
    private static func isMenuOpen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        let ignoredOwners: Set<String> = ["Window Server", "MenuBarAgent", "Dock", "Notification Center"]
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        return windows.contains { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? Int ?? 0
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let hasSize = (bounds["Width"] ?? 0) > 1 && (bounds["Height"] ?? 0) > 1
            let isMenuLevel = layer == Int(CGWindowLevelForKey(.popUpMenuWindow))
                || layer == Int(CGWindowLevelForKey(.statusWindow))
            return isMenuLevel && hasSize && pid != ownPID && !ignoredOwners.contains(owner)
        }
    }

    // MARK: - Preferences

    private func preferencesChanged() {
        updateAppearance()
        if !isCollapsed {
            separatorItem.length = expandedSeparatorLength
            if autoCollapseTimer != nil || prefs.autoCollapse {
                scheduleAutoCollapse()
            }
        }
        updateMouseMonitoring()
        updateHotKey()
    }

    private func updateHotKey() {
        let combo = hotKeySuspended ? nil : prefs.hotKey
        guard combo != registeredCombo || (combo != nil && hotKey == nil) else { return }
        hotKey = nil
        registeredCombo = combo
        guard let combo else {
            hotKeyUnavailable = false
            return
        }
        hotKey = GlobalHotKey(combo: combo) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        // Registration fails when another app already owns the combination.
        hotKeyUnavailable = hotKey == nil
    }
}

extension NSScreen {
    /// Left edge of the menu bar area right of the camera housing, in global coordinates; nil without a notch.
    var notchRightEdge: CGFloat? {
        guard safeAreaInsets.top > 0, let area = auxiliaryTopRightArea, area.width > 0 else { return nil }
        // Depending on the system the area comes back screen-local or global; normalise to global.
        let isLocal = area.minX < frame.minX - 1 || area.maxX > frame.maxX + 1
        return isLocal ? frame.minX + area.minX : area.minX
    }
}
