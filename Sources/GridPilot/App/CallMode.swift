import AppKit
import SQLite3

/// True if a notification's text smells like a ringing call rather than a
/// missed-call summary or a chat message.
func matchesRingingCall(title: String, body: String) -> Bool {
    let text = "\(title) \(body)".lowercased()
    let negative = ["missed", "voicemail", "call ended", "declined"]
    if negative.contains(where: text.contains) { return false }
    let positive = ["incoming call", "is calling", "audio call", "video call", "facetime", "wants to talk", "huddle", "ringing", "calling you"]
    return positive.contains(where: text.contains)
}

/// While a call rings: buttons B1/B2 are hijacked (answer / silence), LEDs
/// blink, everything auto-reverts on timeout or answer.
final class CallModeController {
    private(set) var active = false
    private var ringingApp: String?
    private var flashTimer: Timer?
    private var timeoutWork: DispatchWorkItem?
    private var savedVolume: Float?
    private let store: ConfigStore
    private let midiSend: (MIDIMessageType, Int, Int, Int) -> Void

    init(store: ConfigStore, midiSend: @escaping (MIDIMessageType, Int, Int, Int) -> Void) {
        self.store = store
        self.midiSend = midiSend
    }

    private var callConfig: CallConfig { store.config.call ?? .standard }

    func enter(bundleID: String) {
        guard callConfig.enabled else { return }
        // A second ring while active just resets the clock.
        ringingApp = bundleID
        armTimeout()
        guard !active else { return }
        active = true
        Log.info("call mode: ringing from \(bundleID)")
        if callConfig.flashLEDs { startFlashing() }
    }

    func exit() {
        guard active else { return }
        active = false
        ringingApp = nil
        timeoutWork?.cancel()
        stopFlashing()
        if let volume = savedVolume {
            Audio.setOutputVolume(volume)
            savedVolume = nil
        }
        Log.info("call mode: ended")
    }

    /// Returns true if the event was consumed (B1/B2 press or release while ringing).
    func intercept(_ event: MIDIEvent) -> Bool {
        guard active else { return false }
        let controls = store.config.controls
        func matches(_ name: String) -> Bool {
            controls[name]?.matches(event) ?? false
        }
        if matches("B1") {
            if event.value >= 64 { answer() }
            return true
        }
        if matches("B2") {
            if event.value >= 64 { silence() }
            return true
        }
        return false
    }

    private func answer() {
        guard let bundleID = ringingApp else { return exit() }
        let app = callConfig.apps[bundleID]
        Log.info("call mode: answering \(app?.name ?? bundleID)")
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        if let key = app?.answerKey {
            // Give the app a beat to come frontmost before the shortcut lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Keystroke.send(key)
            }
        }
        exit()
    }

    /// Silence, not reject: kill our LED noise and mute the ring; the call
    /// keeps ringing for the caller. Volume comes back when the ring times out.
    private func silence() {
        stopFlashing()
        if savedVolume == nil {
            savedVolume = Audio.getOutputVolume()
        }
        Audio.setOutputVolume(0)
        Log.info("call mode: silenced")
    }

    private func armTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.exit() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(callConfig.ringTimeoutSec), execute: work)
    }

    private func startFlashing() {
        var on = false
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            on.toggle()
            self.sendToButtons(value: on ? 127 : 0)
        }
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        sendToButtons(value: 0)
    }

    private func sendToButtons(value: Int) {
        for name in ["B1", "B2", "B3", "B4"] {
            if let control = store.config.controls[name] {
                midiSend(control.type, control.cc, value, 0)
            }
        }
    }
}

/// Polls the Notification Center database for ringing-call notifications from
/// the configured apps. Needs Full Disk Access; degrades to "manual trigger
/// only" without it (see `gridpilot notify --event call:<bundleid>`).
final class CallWatcher {
    private let store: ConfigStore
    private let onRing: (String) -> Void
    private var timer: Timer?
    private var lastSeen: Double
    private var warnedNoAccess = false

    private static var dbPath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    }

    init(store: ConfigStore, onRing: @escaping (String) -> Void) {
        self.store = store
        self.onRing = onRing
        // Core Data reference date (2001-01-01) seconds, starting from "now".
        self.lastSeen = Date().timeIntervalSinceReferenceDate
    }

    func start() {
        guard (store.config.call ?? .standard).enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if !warnedNoAccess {
                warnedNoAccess = true
                Log.info("call watcher: no Full Disk Access — automatic call detection off (manual trigger still works)")
            }
            stop()
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT app.identifier, record.data, record.delivered_date
        FROM record JOIN app ON record.app_id = app.app_id
        WHERE record.delivered_date > ?
        ORDER BY record.delivered_date ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, lastSeen)

        let apps = (store.config.call ?? .standard).apps
        while sqlite3_step(statement) == SQLITE_ROW {
            let delivered = sqlite3_column_double(statement, 2)
            lastSeen = max(lastSeen, delivered)
            guard let idCStr = sqlite3_column_text(statement, 0) else { continue }
            let bundleID = String(cString: idCStr)
            guard apps.keys.contains(bundleID) else { continue }
            guard let blob = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
            let (title, body) = Self.notificationText(from: data)
            if matchesRingingCall(title: title, body: body) {
                DispatchQueue.main.async { self.onRing(bundleID) }
            }
        }
    }

    /// record.data is a binary plist: {"req": {"titl": ..., "subt": ..., "body": ...}, ...}
    static func notificationText(from data: Data) -> (title: String, body: String) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any] else {
            return ("", "")
        }
        let title = [request["titl"], request["subt"]].compactMap { $0 as? String }.joined(separator: " ")
        let body = request["body"] as? String ?? ""
        return (title, body)
    }
}
