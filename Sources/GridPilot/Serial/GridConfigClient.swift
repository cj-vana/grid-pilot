import Foundation

/// Talks the Grid protocol over the CDC serial port: discovery via
/// heartbeats, config read/write, page store. Opens the port on demand —
/// Grid Editor and GridPilot cannot hold it at the same time.
final class GridConfigClient {
    static let classConfig = 0x060
    static let classPageStore = 0x061
    static let instrFetch = 0xF
    static let instrAck = 0xA
    static let instrNack = 0xB
    static let instrReport = 0xD
    static let systemElement = 255
    static let setupEvent = 0
    static let maxActionLength = 908  // editor rejects >= 909

    private let port: SerialPort
    private var splitter = GridProtocol.FrameSplitter()
    private let session: UInt8 = UInt8.random(in: 1...255)
    private var nextID: UInt8 = 1
    private var heartbeatTimer: Timer?
    private(set) var modules: [GridModule] = []
    var onModulesChanged: (([GridModule]) -> Void)?

    /// Pending request waiting for a semantically-matching reply.
    private struct Pending {
        var matches: ([UInt8]) -> Bool?
        var complete: (Result<[UInt8], String>) -> Void
    }
    private var pending: Pending?
    private let lock = NSLock()

    init(portPath: String) {
        self.port = SerialPort(path: portPath)
        port.onData = { [weak self] data in self?.receive(data) }
    }

    static func openFirstAvailable() -> GridConfigClient? {
        for path in SerialPort.candidatePaths() {
            let client = GridConfigClient(portPath: path)
            if client.start() { return client }
        }
        return nil
    }

    func start() -> Bool {
        guard port.open() else { return false }
        sendHostHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.sendHostHeartbeat()
            self?.pruneStaleModules()
        }
        return true
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        port.close()
    }

    private func takeID() -> UInt8 {
        let id = nextID
        nextID = nextID == 255 ? 1 : nextID + 1
        return id
    }

    private func sendHostHeartbeat() {
        port.write(GridProtocol.hostHeartbeat(id: takeID(), session: session))
    }

    private func receive(_ data: Data) {
        for frame in splitter.ingest(data) {
            guard let body = GridProtocol.validateFrame(frame) else { continue }
            if let heartbeat = GridProtocol.decodeHeartbeat(body) {
                noteModule(heartbeat)
                continue
            }
            lock.lock()
            let waiter = pending
            lock.unlock()
            if let waiter, let matched = waiter.matches(body) {
                lock.lock()
                pending = nil
                lock.unlock()
                waiter.complete(matched ? .success(body) : .failure("module NACKed the request"))
            }
        }
    }

    private func noteModule(_ heartbeat: GridProtocol.Heartbeat) {
        let module = GridModule(
            x: heartbeat.x, y: heartbeat.y, hwcfg: heartbeat.hwcfg,
            firmware: (heartbeat.major, heartbeat.minor, heartbeat.patch),
            lastSeen: Date()
        )
        if let index = modules.firstIndex(where: { $0.x == module.x && $0.y == module.y }) {
            let changed = modules[index] != module
            modules[index] = module
            if changed { onModulesChanged?(modules) }
        } else {
            modules.append(module)
            modules.sort { ($0.y, $0.x) < ($1.y, $1.x) }
            onModulesChanged?(modules)
        }
    }

    private func pruneStaleModules() {
        let cutoff = Date().addingTimeInterval(-2)
        let alive = modules.filter { $0.lastSeen > cutoff }
        if alive.count != modules.count {
            modules = alive
            onModulesChanged?(modules)
        }
    }

    // MARK: Requests

    /// Blocks the calling (non-main) thread until reply or timeout.
    private func request(
        _ packet: Data,
        timeout: TimeInterval,
        matches: @escaping ([UInt8]) -> Bool?
    ) -> Result<[UInt8], String> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<[UInt8], String> = .failure("timed out after \(timeout)s")
        lock.lock()
        pending = Pending(matches: matches) { result in
            outcome = result
            semaphore.signal()
        }
        lock.unlock()
        port.write(packet)
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        pending = nil
        lock.unlock()
        return outcome
    }

    /// Reply matcher: checks source coords, class code, and instruction.
    /// Returns nil (keep waiting), true (success), or false (NACK).
    private static func replyMatcher(dx: Int, dy: Int, classCode: Int) -> ([UInt8]) -> Bool? {
        { body in
            func hexInt(_ range: Range<Int>) -> Int? {
                guard range.upperBound <= body.count,
                      let text = String(bytes: body[range], encoding: .ascii) else { return nil }
                return Int(text, radix: 16)
            }
            guard let sx = hexInt(10..<12), let sy = hexInt(12..<14) else { return nil }
            // Global requests (-127,-127) accept a reply from any module.
            let coordsMatch = (sx - 127 == dx && sy - 127 == dy) || (dx == -127 && dy == -127)
            guard coordsMatch,
                  let stx = body.firstIndex(of: GridProtocol.STX),
                  let code = hexInt((stx + 1)..<(stx + 4)),
                  code == classCode,
                  let instr = hexInt((stx + 4)..<(stx + 5)) else { return nil }
            if instr == instrNack { return false }
            if instr == instrAck || instr == instrReport { return true }
            return nil
        }
    }

    func writeConfig(module: GridModule, element: Int, event: Int, script: String, page: Int = 0) -> Result<Void, String> {
        let bytes = Array(script.utf8)
        guard bytes.count <= Self.maxActionLength else {
            return .failure("script is \(bytes.count) bytes; module limit is \(Self.maxActionLength)")
        }
        let forbidden: Set<UInt8> = [0x01, 0x02, 0x03, 0x04, 0x0A, 0x0F, 0x17]
        guard !bytes.contains(where: { forbidden.contains($0) }) else {
            return .failure("script contains protocol control bytes (newlines?) — minify first")
        }
        var params: [UInt8] = []
        params += GridProtocol.hexParam(1, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        params += GridProtocol.hexParam(page, width: 2)
        params += GridProtocol.hexParam(element, width: 2)
        params += GridProtocol.hexParam(event, width: 2)
        params += GridProtocol.hexParam(bytes.count, width: 4)
        params += bytes
        let section = GridProtocol.classSection(code: Self.classConfig, instruction: GridProtocol.instrExecute, params: params)
        let packet = GridProtocol.packet(
            id: takeID(), session: session,
            to: GridProtocol.Address(dx: module.x, dy: module.y), classSection: section
        )
        let matcher = Self.replyMatcher(dx: module.x, dy: module.y, classCode: Self.classConfig)
        // Editor uses 500ms + retries; we do one retry.
        for attempt in 0..<2 {
            switch request(packet, timeout: 0.5, matches: matcher) {
            case .success: return .success(())
            case .failure(let message):
                if attempt == 1 { return .failure(message) }
            }
        }
        return .failure("unreachable")
    }

    func fetchConfig(module: GridModule, element: Int, event: Int, page: Int = 0) -> Result<String, String> {
        var params: [UInt8] = []
        params += GridProtocol.hexParam(1, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        params += GridProtocol.hexParam(page, width: 2)
        params += GridProtocol.hexParam(element, width: 2)
        params += GridProtocol.hexParam(event, width: 2)
        params += GridProtocol.hexParam(0, width: 4)
        let section = GridProtocol.classSection(code: Self.classConfig, instruction: Self.instrFetch, params: params)
        let packet = GridProtocol.packet(
            id: takeID(), session: session,
            to: GridProtocol.Address(dx: module.x, dy: module.y), classSection: section
        )
        let result = request(packet, timeout: 1.0, matches: Self.replyMatcher(dx: module.x, dy: module.y, classCode: Self.classConfig))
        switch result {
        case .failure(let message):
            return .failure(message)
        case .success(let body):
            // ACTIONSTRING = raw bytes after the fixed param block, up to ETX.
            guard let stx = body.firstIndex(of: GridProtocol.STX),
                  let etx = body.lastIndex(of: GridProtocol.ETX),
                  stx + 21 <= etx else {
                return .failure("malformed CONFIG report")
            }
            let script = String(bytes: body[(stx + 21)..<etx], encoding: .utf8) ?? ""
            return .success(script)
        }
    }

    /// Persist the active page on every module. Global broadcast, one ACK
    /// per... the head ACKs for the chain; editor waits up to 3s.
    func storePages() -> Result<Void, String> {
        let section = GridProtocol.classSection(code: Self.classPageStore, instruction: GridProtocol.instrExecute, params: [])
        let packet = GridProtocol.packet(id: takeID(), session: session, to: .global, classSection: section)
        let matcher = Self.replyMatcher(dx: -127, dy: -127, classCode: Self.classPageStore)
        switch request(packet, timeout: 3.0, matches: matcher) {
        case .success: return .success(())
        case .failure(let message): return .failure(message)
        }
    }
}
