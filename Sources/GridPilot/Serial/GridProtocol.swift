import Foundation

/// Grid serial protocol framing (v1.5.5), per intechstudio/grid-protocol.
/// Numeric fields ride as lowercase ASCII-hex; structure markers are raw
/// control bytes. One class section per host packet.
enum GridProtocol {
    // Control bytes
    static let SOH: UInt8 = 0x01
    static let STX: UInt8 = 0x02
    static let ETX: UInt8 = 0x03
    static let EOT: UInt8 = 0x04
    static let LF: UInt8 = 0x0A
    static let BRC: UInt8 = 0x0F
    static let EOB: UInt8 = 0x17

    struct Address {
        /// Module coordinates relative to the USB module; host = (-127, -127).
        var dx: Int
        var dy: Int
        static let global = Address(dx: -127, dy: -127)
    }

    private static func hex(_ value: Int, width: Int) -> [UInt8] {
        let clamped = max(0, value)
        let text = String(format: "%0\(width)x", clamped)
        return Array(text.utf8.suffix(width))
    }

    /// XOR-8 over SOH..EOT inclusive, as two lowercase hex chars.
    static func checksum(_ bytes: [UInt8]) -> [UInt8] {
        var sum: UInt8 = 0
        for byte in bytes { sum ^= byte }
        return hex(Int(sum), width: 2)
    }

    /// Assembles a full wire packet around one encoded class section
    /// (STX...ETX supplied by the caller-specific encoders below).
    static func packet(id: UInt8, session: UInt8, to address: Address, classSection: [UInt8]) -> Data {
        var body: [UInt8] = [SOH, BRC]
        // LEN placeholder, patched after assembly (counts SOH..EOT).
        body += hex(0, width: 4)
        body += hex(Int(id), width: 2)
        body += hex(Int(session), width: 2)
        body += hex(0, width: 2)                    // SX: host = -127 + 127 = 0
        body += hex(0, width: 2)                    // SY
        body += hex(address.dx + 127, width: 2)
        body += hex(address.dy + 127, width: 2)
        body += Array("00".utf8)                    // ROT + PORTROT nibbles
        body += hex(0, width: 2)                    // MSGAGE
        body.append(EOB)
        body += classSection
        body.append(EOT)
        let lenField = hex(body.count, width: 4)
        body.replaceSubrange(2..<6, with: lenField)
        body += checksum(body)
        body.append(LF)
        return Data(body)
    }

    /// Builds a class section: STX + 3-hex class code + 1-hex instruction +
    /// params (already hex/raw encoded) + ETX.
    static func classSection(code: Int, instruction: Int, params: [UInt8]) -> [UInt8] {
        var section: [UInt8] = [STX]
        section += hex(code, width: 3)
        section += hex(instruction, width: 1)
        section += params
        section.append(ETX)
        return section
    }

    static func hexParam(_ value: Int, width: Int) -> [UInt8] {
        hex(value, width: width)
    }

    /// Splits an RX byte stream into frames. A frame ends at LF preceded
    /// three bytes earlier by EOT (tail: EOT ck ck LF). Returns complete
    /// frames (SOH..checksum, LF stripped) and leaves the remainder buffered.
    struct FrameSplitter {
        private var buffer: [UInt8] = []

        mutating func ingest(_ data: Data) -> [[UInt8]] {
            buffer.append(contentsOf: data)
            var frames: [[UInt8]] = []
            var start = 0
            var index = 3
            while index < buffer.count {
                if buffer[index] == LF && buffer[index - 3] == EOT {
                    frames.append(Array(buffer[start..<index]))
                    start = index + 1
                    index = start + 3
                } else {
                    index += 1
                }
            }
            buffer.removeFirst(start)
            // Unframed garbage guard: don't buffer unbounded noise.
            if buffer.count > 65536 { buffer.removeAll() }
            return frames
        }
    }

    /// Verifies checksum and returns the frame body if intact.
    static func validateFrame(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count > 4, frame[0] == SOH else { return nil }
        let body = Array(frame[0..<(frame.count - 2)])
        let expected = Array(frame[(frame.count - 2)...])
        return checksum(body) == expected ? body : nil
    }
}
