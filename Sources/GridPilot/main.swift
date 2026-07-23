import AppKit
import CoreMIDI

// Subcommands run headless; bare launch is the menu-bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    exit(CLI.run(arguments))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
