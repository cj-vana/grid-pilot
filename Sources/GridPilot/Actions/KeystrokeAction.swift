import Foundation
import CoreGraphics
import ApplicationServices

enum Keystroke {
    private static var promptedForAccessibility = false

    static func send(_ key: KeySpec) {
        if !AXIsProcessTrusted() {
            // Prompt once per launch; the event below will no-op until granted.
            if !promptedForAccessibility {
                promptedForAccessibility = true
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                Log.error("Accessibility permission needed for keystrokes — grant GridPilot in System Settings > Privacy & Security > Accessibility")
            }
            return
        }
        var flags: CGEventFlags = []
        for modifier in key.modifiers ?? [] {
            switch modifier.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: Log.error("keystroke: unknown modifier \"\(modifier)\"")
            }
        }
        let code = CGKeyCode(key.keyCode)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
