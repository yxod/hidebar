import AppKit
import ApplicationServices
import os

private let axLogger = Logger(subsystem: "dev.qweb.HideBar", category: "accessibility")

/// Access to the menu bar through the Accessibility API. Optional: without the permission HideBar still hides
/// icons, it just can't press the system » to close the overflow row on its own.
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
