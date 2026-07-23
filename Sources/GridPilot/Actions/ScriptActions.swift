import Foundation

/// {{value}} → 0-127 int, {{percent}} → 0-100 int, {{float}} → 0-1 with two
/// decimals. Buttons (value == nil) substitute empty strings.
func substitute(_ template: String, value: Float?) -> String {
    guard let v = value else {
        return template
            .replacingOccurrences(of: "{{value}}", with: "")
            .replacingOccurrences(of: "{{percent}}", with: "")
            .replacingOccurrences(of: "{{float}}", with: "")
    }
    return template
        .replacingOccurrences(of: "{{value}}", with: String(Int((v * 127).rounded())))
        .replacingOccurrences(of: "{{percent}}", with: String(Int((v * 100).rounded())))
        .replacingOccurrences(of: "{{float}}", with: String(format: "%.2f", v))
}

enum Scripts {
    private static let queue = DispatchQueue(label: "io.gridpilot.applescript")

    /// NSAppleScript is not thread-safe and mustn't block the MIDI path, so
    /// everything funnels through one background queue.
    static func runAppleScript(_ source: String) {
        queue.async {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            script?.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
                Log.error("AppleScript failed: \(message) [\(source.prefix(80))]")
            }
        }
    }

    static func spotify(_ command: String) {
        runAppleScript("tell application \"Spotify\" to \(command)")
    }

    static func spotifyIfRunning(_ command: String) {
        runAppleScript("""
        if application "Spotify" is running then
            tell application "Spotify" to \(command)
        end if
        """)
    }

    static func setAlertVolume(_ value: Float) {
        let level = Int((min(max(value, 0), 1) * 100).rounded())
        runAppleScript("set volume alert volume \(level)")
    }

    static func newITermTab(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        runAppleScript("""
        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window to write text "\(escaped)"
        end tell
        """)
    }

    static func selectITermTab(index: Int) {
        runAppleScript("""
        tell application "iTerm2"
            if (count of windows) > 0 then
                tell current window
                    if (count of tabs) ≥ \(index) then select tab \(index)
                end tell
            end if
        end tell
        """)
    }

    /// Synchronous; only call from the tab-picker path which is already
    /// coalesced and off the hot loop.
    static func itermTabCount() -> Int {
        var error: NSDictionary?
        let script = NSAppleScript(source: """
        tell application "iTerm2"
            if (count of windows) = 0 then return 0
            return count of tabs of current window
        end tell
        """)
        let result = script?.executeAndReturnError(&error)
        if let error {
            Log.error("itermTabCount failed: \(error[NSAppleScript.errorMessage] ?? error)")
            return 0
        }
        return Int(result?.int32Value ?? 0)
    }

    static func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.terminationHandler = { p in
            if p.terminationStatus != 0 {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: data, encoding: .utf8) ?? ""
                Log.error("shell exited \(p.terminationStatus): \(command.prefix(80)) — \(err.prefix(200))")
            }
        }
        do {
            try process.run()
        } catch {
            Log.error("shell launch failed: \(error.localizedDescription)")
        }
    }

    static func screenshot(interactive: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = interactive ? ["-i", "-c"] : ["-c"]
        try? process.run()
    }
}
