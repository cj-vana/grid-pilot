import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreMIDI

enum CLI {
    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "ai":
            return ai(request: arguments.dropFirst().filter { $0 != "--yes" }.joined(separator: " "),
                      autoConfirm: arguments.contains("--yes"))
        case "notify":
            return notify(arguments: Array(arguments.dropFirst()))
        case "doctor":
            return doctor()
        case "schema":
            print(AIPrompt.schemaDoc)
            return 0
        case "config-path":
            print(ConfigStore.defaultPath.path)
            return 0
        case "rollback":
            return rollback()
        case "preset":
            return preset(arguments: Array(arguments.dropFirst()))
        case "modules":
            return modules()
        case "setup-leds":
            return setupLEDs()
        case "generate-map":
            return generateMap()
        case "fetch-config":
            // Debug: gridpilot fetch-config <element> <event>
            let args = Array(arguments.dropFirst())
            guard args.count == 2, let element = Int(args[0]), let event = Int(args[1]) else {
                print("usage: gridpilot fetch-config <element 0-255> <event 0-9>")
                return 64
            }
            return fetchConfig(element: element, event: event)
        case "version":
            print("gridpilot \(appVersion)")
            return 0
        default:
            print("""
            gridpilot — Intech Grid PBF4 → macOS control surface

            usage:
              gridpilot                 launch the menu-bar app
              gridpilot ai "<request>"  AI-edit the config in natural language (--yes to skip confirm)
              gridpilot notify --event <name>   ping the running app (flashes icon, sends LED MIDI)
                                        events: anything, plus call:<bundleid> / call-end
              gridpilot rollback        restore the most recent config backup
              gridpilot preset list|save <name>|load <name>   named config snapshots
              gridpilot modules        discover chained Grid modules over serial (quit Grid Editor first)
              gridpilot setup-leds     deploy LED themes to all modules, no Grid Editor needed
              gridpilot generate-map   add controls for all detected modules to the config
              gridpilot doctor          check device, permissions, and AI CLIs
              gridpilot schema          print the config schema the AI sees
              gridpilot config-path     print the config file location
              gridpilot version
            """)
            return arguments.isEmpty ? 0 : 64
        }
    }

    static let appVersion = "0.3.0"

    private static func ai(request: String, autoConfirm: Bool) -> Int32 {
        guard !request.isEmpty else {
            print("usage: gridpilot ai \"<what you want changed>\" [--yes]")
            return 64
        }
        let store = ConfigStore()
        store.loadOrCreate()
        let ai = store.config.ai
        let model = ai.provider == "claude" ? ai.claude.model : ai.codex.model
        print("asking \(ai.provider) (\(model))…")

        var exitCode: Int32 = 1
        let semaphore = DispatchSemaphore(value: 0)
        AICustomizer(store: store).customize(request: request) { result in
            switch result {
            case .failure(let message):
                print("✗ \(message)")
            case .success(let proposal):
                print("\nProposed change:")
                for line in proposal.summary { print("  • \(line)") }
                let confirmed: Bool
                if autoConfirm {
                    confirmed = true
                } else {
                    print("\nApply? [y/N] ", terminator: "")
                    confirmed = readLine()?.lowercased().hasPrefix("y") ?? false
                }
                guard confirmed else {
                    print("aborted, nothing changed")
                    exitCode = 0
                    break
                }
                do {
                    try AICustomizer(store: store).apply(proposal)
                    print("✓ applied — the running app hot-reloads automatically. `gridpilot rollback` undoes.")
                    exitCode = 0
                } catch {
                    print("✗ \(error.localizedDescription)")
                }
            }
            semaphore.signal()
        }
        // RunLoop keeps NSAppleScript compilation happy while we wait.
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return exitCode
    }

    private static func notify(arguments: [String]) -> Int32 {
        var event = "attention"
        if let flagIndex = arguments.firstIndex(of: "--event"), flagIndex + 1 < arguments.count {
            event = arguments[flagIndex + 1]
        }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("io.gridpilot.notify"),
            object: event, userInfo: nil, deliverImmediately: true
        )
        print("sent \(event)")
        return 0
    }

    private static func modules() -> Int32 {
        guard let client = GridConfigClient.openFirstAvailable() else {
            print("✗ no Grid serial port available — plug in the Grid and quit Grid Editor (the port is exclusive)")
            return 1
        }
        defer { client.stop() }
        // Modules heartbeat every 250 ms; give the chain a moment to report.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let modules = client.modules
        if modules.isEmpty {
            print("✗ port opened but no module heartbeats — is the Grid connected?")
            return 1
        }
        print("discovered \(modules.count) module\(modules.count == 1 ? "" : "s"):")
        for module in modules {
            let fw = "\(module.firmware.major).\(module.firmware.minor).\(module.firmware.patch)"
            let head = module.x == 0 && module.y == 0 ? "  [USB head]" : ""
            print("  \(module.name) at (\(module.x),\(module.y))  fw \(fw)  hwcfg \(module.hwcfg)\(head)")
        }
        return 0
    }

    private static func setupLEDs() -> Int32 {
        guard let client = GridConfigClient.openFirstAvailable() else {
            print("✗ no Grid serial port — quit Grid Editor first (the port is exclusive)")
            return 1
        }
        defer { client.stop() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        print("deploying LED theme setup to \(client.modules.count) module(s)…")
        let report = LEDDeployer.deploy(client: client)
        for line in report.lines { print("  \(line)") }
        if !report.failed {
            print("done — restart GridPilot (or replug the Grid) so it re-sends your theme")
        }
        return report.failed ? 1 : 0
    }

    private static func generateMap() -> Int32 {
        guard let client = GridConfigClient.openFirstAvailable() else {
            print("✗ no Grid serial port — quit Grid Editor first")
            return 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let modules = client.modules
        client.stop()
        guard !modules.isEmpty else {
            print("✗ no module heartbeats")
            return 1
        }
        let store = ConfigStore()
        store.loadOrCreate()
        let (merged, added) = MapGenerator.merge(into: store.config, modules: modules)
        guard !added.isEmpty else {
            print("all \(modules.count) module(s) already covered by the config")
            return 0
        }
        do {
            try store.apply(merged, backup: true)
            print("✓ added \(added.count) controls: \(added.joined(separator: ", "))")
            print("assign actions with e.g.: gridpilot ai \"put spotify seek on \(added.first!)\"")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    private static func fetchConfig(element: Int, event: Int) -> Int32 {
        guard let client = GridConfigClient.openFirstAvailable() else {
            print("✗ no Grid serial port — quit Grid Editor first")
            return 1
        }
        defer { client.stop() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        guard let module = client.modules.first(where: { $0.x == 0 && $0.y == 0 }) ?? client.modules.first else {
            print("✗ no module heartbeats")
            return 1
        }
        switch client.fetchConfig(module: module, element: element, event: event) {
        case .success(let script):
            print("— \(module.name) element \(element) event \(event) (\(script.utf8.count) bytes) —")
            print(script)
            return 0
        case .failure(let message):
            print("✗ \(message)")
            return 1
        }
    }

    private static func preset(arguments: [String]) -> Int32 {
        let store = ConfigStore()
        store.loadOrCreate()
        switch arguments.first {
        case "list", nil:
            let names = store.presets()
            if names.isEmpty {
                print("no presets — save one with: gridpilot preset save <name>")
            } else {
                let active = store.presetMatchingCurrent()
                for name in names { print("\(name == active ? "* " : "  ")\(name)") }
            }
            return 0
        case "save":
            guard arguments.count > 1 else { print("usage: gridpilot preset save <name>"); return 64 }
            do {
                try store.savePreset(named: arguments.dropFirst().joined(separator: " "))
                print("✓ saved")
                return 0
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
        case "load":
            guard arguments.count > 1 else { print("usage: gridpilot preset load <name>"); return 64 }
            do {
                try store.loadPreset(named: arguments.dropFirst().joined(separator: " "))
                print("✓ loaded — running app hot-reloads automatically")
                return 0
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
        default:
            print("usage: gridpilot preset list|save <name>|load <name>")
            return 64
        }
    }

    private static func rollback() -> Int32 {
        let store = ConfigStore()
        store.loadOrCreate()
        do {
            try store.rollback()
            print("✓ rolled back")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    private static func doctor() -> Int32 {
        func check(_ label: String, _ ok: Bool, hint: String = "") {
            print("  \(ok ? "✓" : "✗") \(label)\(ok || hint.isEmpty ? "" : " — \(hint)")")
        }
        print("gridpilot doctor\n")

        let store = ConfigStore()
        let config = store.loadOrCreate()
        print("config: \(store.path.path)")

        var found = false
        for i in 0..<MIDIGetNumberOfSources() {
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &name)
            if let n = name?.takeRetainedValue() as String?, n.localizedCaseInsensitiveContains(config.midi.deviceName) {
                found = true
            }
        }
        check("MIDI device \"\(config.midi.deviceName)\"", found, hint: "plug in the Grid / check the USB cable")
        check("Accessibility (keystrokes)", AXIsProcessTrusted(), hint: "System Settings > Privacy & Security > Accessibility")
        check("Screen Recording (screenshots)", CGPreflightScreenCaptureAccess(), hint: "System Settings > Privacy & Security > Screen Recording")

        let fm = FileManager.default
        check("Spotify installed", fm.fileExists(atPath: "/Applications/Spotify.app"))
        check("iTerm installed", fm.fileExists(atPath: "/Applications/iTerm.app"))
        check("codex CLI", commandExists("codex"), hint: "npm i -g @openai/codex (or switch ai.provider to claude)")
        check("claude CLI", commandExists("claude"), hint: "https://claude.com/claude-code (or switch ai.provider to codex)")

        let notifDB = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
        let callDetection = FileManager.default.isReadableFile(atPath: notifDB)
        check("Full Disk Access (auto call detection)", callDetection, hint: "optional; System Settings > Privacy & Security > Full Disk Access")

        let serialCandidates = SerialPort.candidatePaths()
        check("Grid serial port (module setup/discovery)", !serialCandidates.isEmpty,
              hint: "appears when the Grid is plugged in; quit Grid Editor before gridpilot modules/setup-leds — the port is exclusive")
        return 0
    }

    private static func commandExists(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-lc", "command -v \(name)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
