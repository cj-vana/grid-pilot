import Foundation

/// Owns the config file: load/create, apply-with-backup, rollback, and a
/// file watcher so hand edits (or a CLI `gridpilot ai` run from another
/// process) hot-reload into the running app.
final class ConfigStore {
    let path: URL
    private(set) var config: Config
    var onChange: ((Config) -> Void)?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var reloadWork: DispatchWorkItem?
    /// Set while we write, so the watcher ignores our own saves.
    private var selfWriteUntil = Date.distantPast
    private let maxBackups = 20

    var backupsDir: URL { path.deletingLastPathComponent().appendingPathComponent("backups") }

    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gridpilot/config.json")
    }

    init(path: URL = ConfigStore.defaultPath) {
        self.path = path
        self.config = .default
    }

    @discardableResult
    func loadOrCreate() -> Config {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: path) {
            do {
                let loaded = try Config.decode(data)
                let problems = ConfigValidator.validate(loaded)
                if problems.isEmpty {
                    config = loaded
                    return config
                }
                Log.error("config invalid, using defaults: \(problems.joined(separator: "; "))")
            } catch {
                Log.error("config unreadable, using defaults: \(error.localizedDescription)")
            }
            return config
        }
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? config.encodePretty().write(to: path)
        Log.info("created default config at \(path.path)")
        return config
    }

    func apply(_ new: Config, backup: Bool) throws {
        let problems = ConfigValidator.validate(new)
        guard problems.isEmpty else {
            throw NSError(domain: "GridPilot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "invalid config: \(problems.joined(separator: "; "))"
            ])
        }
        if backup, let current = try? Data(contentsOf: path) {
            let fm = FileManager.default
            try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? current.write(to: backupsDir.appendingPathComponent("\(stamp).json"))
            prune()
        }
        selfWriteUntil = Date().addingTimeInterval(1.0)
        try new.encodePretty().write(to: path)
        config = new
        onChange?(new)
    }

    @discardableResult
    func rollback() throws -> Config {
        guard let newest = backups().first else {
            throw NSError(domain: "GridPilot", code: 2, userInfo: [NSLocalizedDescriptionKey: "no backups to roll back to"])
        }
        let data = try Data(contentsOf: newest)
        let restored = try Config.decode(data)
        try apply(restored, backup: false)
        try FileManager.default.removeItem(at: newest)
        Log.info("rolled back to \(newest.lastPathComponent)")
        return restored
    }

    func backups() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: Presets — named full-config snapshots, switchable from the menu.

    var presetsDir: URL { path.deletingLastPathComponent().appendingPathComponent("presets") }

    func presets() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: presetsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func savePreset(named name: String) throws {
        let safe = Self.presetFileName(name)
        guard !safe.isEmpty else {
            throw NSError(domain: "GridPilot", code: 3, userInfo: [NSLocalizedDescriptionKey: "preset name is empty"])
        }
        try FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        try config.encodePretty().write(to: presetsDir.appendingPathComponent("\(safe).json"))
        Log.info("preset saved: \(safe)")
    }

    func loadPreset(named name: String) throws {
        let url = presetsDir.appendingPathComponent("\(Self.presetFileName(name)).json")
        let preset = try Config.decode(Data(contentsOf: url))
        try apply(preset, backup: true)
        Log.info("preset loaded: \(name)")
    }

    /// Name of the preset identical to the live config, for the menu checkmark.
    func presetMatchingCurrent() -> String? {
        for name in presets() {
            let url = presetsDir.appendingPathComponent("\(name).json")
            if let data = try? Data(contentsOf: url), let preset = try? Config.decode(data), preset == config {
                return name
            }
        }
        return nil
    }

    static func presetFileName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    func startWatching() {
        stopWatching()
        watchedDescriptor = open(path.path, O_EVTONLY)
        guard watchedDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.scheduleReload()
            // Editors save atomically (rename over the file), which kills the
            // descriptor — re-arm on the new inode.
            if events.contains(.delete) || events.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.startWatching() }
            }
        }
        source.setCancelHandler { [descriptor = watchedDescriptor] in close(descriptor) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reloadFromDisk() {
        guard Date() > selfWriteUntil else { return }
        guard let data = try? Data(contentsOf: path) else { return }
        do {
            let loaded = try Config.decode(data)
            let problems = ConfigValidator.validate(loaded)
            guard problems.isEmpty else {
                Log.error("edited config rejected: \(problems.joined(separator: "; "))")
                return
            }
            guard loaded != config else { return }
            config = loaded
            Log.info("config hot-reloaded")
            onChange?(loaded)
        } catch {
            Log.error("edited config unparseable: \(error.localizedDescription)")
        }
    }

    private func prune() {
        for stale in backups().dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
