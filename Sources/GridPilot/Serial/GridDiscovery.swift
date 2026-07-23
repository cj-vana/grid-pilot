import Foundation

/// One module in the chain, as learned from its 250 ms heartbeats.
struct GridModule: Equatable {
    var x: Int
    var y: Int
    var hwcfg: Int
    var firmware: (major: Int, minor: Int, patch: Int)
    var lastSeen: Date

    var name: String { GridModuleCatalog.name(hwcfg: hwcfg) }

    static func == (lhs: GridModule, rhs: GridModule) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.hwcfg == rhs.hwcfg
    }
}

enum GridElementType {
    case potmeter
    case button
    case encoder
    case endless
    case touch
}

enum GridModuleCatalog {
    /// hwcfg → module family. From grid_protocol_bot.json GRID_MODULE_*.
    private static let families: [Int: String] = [
        0: "PO16", 8: "PO16", 1: "PO16", 3: "PO16", 11: "PO16",
        128: "BU16", 136: "BU16", 129: "BU16", 131: "BU16",
        192: "EN16", 193: "EN16", 195: "EN16", 200: "EN16", 201: "EN16", 203: "EN16",
        32: "EF44", 33: "EF44", 35: "EF44", 41: "EF44", 43: "EF44",
        64: "PBF4", 65: "PBF4", 67: "PBF4", 75: "PBF4",
        145: "PB44",
        225: "TEK1", 17: "TEK2", 25: "TEK2", 27: "TEK2",
        49: "VSN1L", 57: "VSN1L", 59: "VSN1L",
        81: "VSN1R", 89: "VSN1R", 91: "VSN1R",
        113: "VSN2", 121: "VSN2", 123: "VSN2",
        211: "OCTV", 219: "OCTV", 161: "XY",
    ]

    static func name(hwcfg: Int) -> String {
        families[hwcfg] ?? "Grid(\(hwcfg))"
    }

    /// Element index → type, for control-map generation. Derived from the
    /// protocol repo's moduleElements tables; families we haven't verified on
    /// hardware return nil and fall back to learn mode.
    static func elements(hwcfg: Int) -> [GridElementType]? {
        switch name(hwcfg: hwcfg) {
        case "PO16": return Array(repeating: .potmeter, count: 16)
        case "BU16": return Array(repeating: .button, count: 16)
        case "EN16": return Array(repeating: .encoder, count: 16)
        case "EF44": return Array(repeating: .encoder, count: 4) + Array(repeating: .potmeter, count: 4)
        case "PBF4": return Array(repeating: .potmeter, count: 8) + Array(repeating: .button, count: 4)
        case "TEK2": return Array(repeating: .endless, count: 2) + Array(repeating: .button, count: 8)
        default: return nil
        }
    }
}

extension GridProtocol {
    static let classHeartbeat = 0x010
    static let instrExecute = 0xE

    /// Host-side heartbeat: announces "editor connected" so modules accept
    /// config traffic. type 255 = normal, 254 = block page changes.
    static func hostHeartbeat(id: UInt8, session: UInt8, type: Int = 255) -> Data {
        var params: [UInt8] = []
        params += hexParam(type, width: 2)
        params += hexParam(255, width: 2)   // HWCFG: host/virtual
        params += hexParam(1, width: 2)     // protocol version 1.5.5
        params += hexParam(5, width: 2)
        params += hexParam(5, width: 2)
        let section = classSection(code: classHeartbeat, instruction: instrExecute, params: params)
        return packet(id: id, session: session, to: .global, classSection: section)
    }

    struct Heartbeat {
        var x: Int
        var y: Int
        var hwcfg: Int
        var major: Int
        var minor: Int
        var patch: Int
    }

    /// Parses a validated frame body; returns nil if it isn't a heartbeat.
    static func decodeHeartbeat(_ body: [UInt8]) -> Heartbeat? {
        guard body.count > 22, body[0] == SOH, body[1] == BRC else { return nil }
        func hexInt(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= body.count,
                  let text = String(bytes: body[range], encoding: .ascii) else { return nil }
            return Int(text, radix: 16)
        }
        guard let sx = hexInt(10..<12), let sy = hexInt(12..<14) else { return nil }
        // Find the class section after EOB.
        guard let stxIndex = body.firstIndex(of: STX), stxIndex + 15 <= body.count else { return nil }
        func classHex(_ offset: Int, _ length: Int) -> Int? {
            let start = stxIndex + offset
            guard start + length <= body.count,
                  let text = String(bytes: body[start..<(start + length)], encoding: .ascii) else { return nil }
            return Int(text, radix: 16)
        }
        guard let code = classHex(1, 3), code == classHeartbeat else { return nil }
        guard let hwcfg = classHex(7, 2), hwcfg != 255,   // 255 = another host
              let major = classHex(9, 2), let minor = classHex(11, 2), let patch = classHex(13, 2) else { return nil }
        return Heartbeat(x: sx - 127, y: sy - 127, hwcfg: hwcfg, major: major, minor: minor, patch: patch)
    }
}
