import AppKit
import Carbon
import SwiftUI

/// A button that records the next key combination pressed while the settings window is focused.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { isRecording ? stop() : start() }) {
                Text(title)
                    .monospacedDigit()
                    .frame(minWidth: 120)
            }
            .help(isRecording ? Text("Esc cancels, ⌫ clears") : Text("Click to record a new shortcut"))

            if combo != nil, !isRecording {
                Button(action: { combo = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(Text("Remove shortcut"))
            }
        }
        .onDisappear(perform: stop)
    }

    private var title: String {
        if isRecording { return NSLocalizedString("Press keys…", comment: "") }
        return combo?.displayString ?? NSLocalizedString("Record Shortcut", comment: "")
    }

    private func start() {
        isRecording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape where modifiers.isEmpty:
                stop()
            case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
                combo = nil
                stop()
            default:
                let candidate = KeyCombo(event: event)
                guard candidate.isValidGlobalShortcut else {
                    NSSound.beep()
                    return nil
                }
                combo = candidate
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            onRecordingChange(false)
        }
    }
}
