import Foundation

/// Minimal POSIX serial wrapper for the Grid's USB CDC port. CDC ignores baud
/// settings; we still put the fd in raw mode so the tty layer doesn't mangle
/// protocol bytes. Ports are exclusive — Grid Editor and GridPilot cannot
/// hold one simultaneously, so open late, close early.
final class SerialPort {
    private var fd: Int32 = -1
    private let path: String
    private var readSource: DispatchSourceRead?
    var onData: ((Data) -> Void)?

    init(path: String) {
        self.path = path
    }

    /// Candidate Grid CDC ports. The Grid enumerates as usbmodem<serial><n>.
    static func candidatePaths() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { $0.hasPrefix("cu.usbmodem") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    func open() -> Bool {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            Log.info("serial: cannot open \(path) (\(String(cString: strerror(errno)))) — is Grid Editor running?")
            return false
        }
        var settings = termios()
        tcgetattr(fd, &settings)
        cfmakeraw(&settings)
        settings.c_cc.16 = 0  // VMIN
        settings.c_cc.17 = 0  // VTIME
        tcsetattr(fd, TCSANOW, &settings)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(self.fd, &buffer, buffer.count)
            if count > 0 {
                self.onData?(Data(buffer[0..<count]))
            }
        }
        source.resume()
        readSource = source
        Log.info("serial: opened \(path)")
        return true
    }

    func write(_ data: Data) {
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 {
                    if errno == EAGAIN { usleep(2000); continue }
                    Log.error("serial: write failed (\(String(cString: strerror(errno))))")
                    return
                }
                offset += written
            }
        }
    }

    func close() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        close()
    }
}
