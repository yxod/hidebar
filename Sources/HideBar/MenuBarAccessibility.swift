import AppKit
import ApplicationServices
import os

private let axLogger = Logger(subsystem: "dev.qweb.HideBar", category: "accessibility")

/// Access to the menu bar through the Accessibility API. Optional: without the permission HideBar still hides
/// icons, it just can't see exactly where each one is or press the system » to close the overflow row.
enum MenuBarAccessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings › Privacy & Security › Accessibility.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Presses the system » on the given screen, closing the overflow row. It is MenuBarAgent's button
    /// "menu-bar-overflow-indicator-expanded" ("…-indicator" while closed, so a closed row is left alone);
    /// AXPress works without moving the pointer.
    @discardableResult
    static func closeOverflowRow(on screen: NSScreen?) -> Bool {
        guard isTrusted, let agent = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return false }
        let buttons = overflowButtons(in: AXUIElementCreateApplication(agent.processIdentifier),
                                      identifier: "menu-bar-overflow-indicator-expanded")
        // Every display's menu bar has its own; accessibility frames share x with screen coordinates.
        let button = buttons.first { element in
            guard let screen, let x = position(of: element)?.x else { return false }
            return x >= screen.frame.minX && x < screen.frame.maxX
        } ?? buttons.first
        guard let button else {
            let root = AXUIElementCreateApplication(agent.processIdentifier)
            axLogger.notice("overflow button not found; buttons: \(describeButtons(in: root), privacy: .public)")
            return false
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        axLogger.notice("pressed »: \(result.rawValue)")
        return result == .success
    }

    /// Accessibility identifiers HideBar gives its own status items, to tell them apart in the menu bar.
    static let identifierPrefix = "dev.qweb.HideBar."

    struct BarItem {
        /// x and width in screen coordinates (accessibility shares x with them; y is flipped).
        let frame: CGRect
        let identifier: String
    }

    struct BarSnapshot {
        let items: [BarItem]
        let overflowButton: CGRect?
    }

    /// What the menu bar shows on the given screen, read from MenuBarAgent: one entry per status item, plus
    /// the « / » button. Overflowed items are parked behind that button.
    static func snapshot(on screen: NSScreen) -> BarSnapshot? {
        guard isTrusted, let agent = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        // Every display has its own menu bar window; accessibility measures y down from the main screen's top.
        let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY
        guard let window = children(of: root).first(where: { element in
            guard role(of: element) == kAXWindowRole, let frame = frame(of: element) else { return false }
            return abs(frame.minY - top) < 4 && frame.midX >= screen.frame.minX && frame.midX < screen.frame.maxX
        }) else { return nil }

        var items: [BarItem] = []
        var overflowButton: CGRect?
        for child in children(of: window) {
            guard let frame = frame(of: child) else { continue }
            let identifier = firstIdentifier(in: child)
            if role(of: child) == kAXButtonRole, identifier.hasPrefix("menu-bar-overflow-indicator") {
                overflowButton = frame
            } else if role(of: child) == kAXGroupRole {
                items.append(BarItem(frame: frame, identifier: identifier))
            }
        }
        return BarSnapshot(items: items, overflowButton: overflowButton)
    }

    /// Right edge of the active app's menus on the given screen; status items can't go left of it.
    static func appMenusMaxX(on screen: NSScreen) -> CGFloat? {
        guard isTrusted, let app = NSWorkspace.shared.menuBarOwningApplication else { return nil }
        guard let menuBar = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute)
        else { return nil }
        return children(of: menuBar as! AXUIElement)
            .compactMap { frame(of: $0) }
            .filter { $0.width > 0 && $0.minX >= screen.frame.minX && $0.maxX <= screen.frame.maxX + 1 }
            .map(\.maxX)
            .max()
    }

    /// Status items keep their identifier on the button inside the group, or deeper for system items.
    private static func firstIdentifier(in element: AXUIElement, depth: Int = 0) -> String {
        if let identifier = attribute(element, "AXIdentifier") as? String, !identifier.isEmpty { return identifier }
        guard depth < 3 else { return "" }
        for child in children(of: element) {
            let identifier = firstIdentifier(in: child, depth: depth + 1)
            if !identifier.isEmpty { return identifier }
        }
        return ""
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func role(of element: AXUIElement) -> String {
        (attribute(element, kAXRoleAttribute) as? String) ?? ""
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = position(of: element), let value = attribute(element, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? CGRect(origin: origin, size: size) : nil
    }

    private static func overflowButtons(in root: AXUIElement, identifier: String) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if (attribute(element, "AXIdentifier") as? String) == identifier {
                found.append(element)
                continue
            }
            guard depth < 4 else { continue }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    private static func describeButtons(in root: AXUIElement) -> String {
        var parts: [String] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if (attribute(element, kAXRoleAttribute) as? String) == kAXButtonRole as String {
                let id = attribute(element, "AXIdentifier") as? String ?? ""
                let desc = attribute(element, kAXDescriptionAttribute) as? String ?? ""
                parts.append("[\(id)|\(desc)|\(Int(position(of: element)?.x ?? -1))]")
            }
            guard depth < 4 else { continue }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                queue.append((child, depth + 1))
            }
        }
        return parts.joined(separator: " ")
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }
}
