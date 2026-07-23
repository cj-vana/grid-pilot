import Foundation
import CoreMIDI

/// Extracts (cc, value, channel) from a MIDI 1.0 Universal MIDI Packet word.
/// UMP MIDI 1.0 channel voice: mt=2 in the top nibble, then group, status byte,
/// data1, data2. Returns nil for anything that isn't a control change.
func parseCC(word: UInt32) -> (cc: Int, value: Int, channel: Int)? {
    let messageType = (word >> 28) & 0xF
    guard messageType == 2 else { return nil }
    let status = (word >> 16) & 0xFF
    guard status & 0xF0 == 0xB0 else { return nil }
    let channel = Int(status & 0x0F)
    let cc = Int((word >> 8) & 0x7F)
    let value = Int(word & 0x7F)
    return (cc, value, channel)
}

/// Connects to every CoreMIDI source whose device name contains `deviceName`,
/// reconnects when the device is replugged, and can send CCs back for LED
/// feedback.
final class MIDIListener {
    private let deviceName: String
    private let onEvent: (Int, Int, Int) -> Void
    private let onStateChange: (Bool) -> Void
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connectedSources: Set<MIDIEndpointRef> = []
    private var destination: MIDIEndpointRef = 0

    init(
        deviceName: String,
        onEvent: @escaping (Int, Int, Int) -> Void,
        onStateChange: @escaping (Bool) -> Void
    ) {
        self.deviceName = deviceName
        self.onEvent = onEvent
        self.onStateChange = onStateChange
    }

    func start() {
        let clientStatus = MIDIClientCreateWithBlock("GridPilot" as CFString, &client) { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgSetupChanged {
                DispatchQueue.main.async { self?.rescan() }
            }
        }
        guard clientStatus == noErr else {
            Log.error("MIDIClientCreate failed: \(clientStatus)")
            return
        }
        MIDIInputPortCreateWithProtocol(client, "GridPilot In" as CFString, ._1_0, &inputPort) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        MIDIOutputPortCreate(client, "GridPilot Out" as CFString, &outputPort)
        rescan()
    }

    func send(cc: Int, value: Int, channel: Int) {
        guard destination != 0 else { return }
        let word: UInt32 = (2 << 28) | (0xB0 | UInt32(channel & 0xF)) << 16 | UInt32(cc & 0x7F) << 8 | UInt32(value & 0x7F)
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size, packet, 0, 1, [word])
        MIDISendEventList(outputPort, destination, &eventList)
    }

    var isConnected: Bool { !connectedSources.isEmpty }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        var events: [(Int, Int, Int)] = []
        var packet = eventList.pointee.packet
        for _ in 0..<eventList.pointee.numPackets {
            let wordCount = Int(packet.wordCount)
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0..<min(wordCount, words.count) {
                    if let event = parseCC(word: words[i]) {
                        events.append(event)
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [onEvent] in
            for (cc, value, channel) in events {
                onEvent(cc, value, channel)
            }
        }
    }

    private func rescan() {
        let wasConnected = isConnected
        var found: Set<MIDIEndpointRef> = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            if endpointMatches(source) {
                found.insert(source)
                if !connectedSources.contains(source) {
                    MIDIPortConnectSource(inputPort, source, nil)
                }
            }
        }
        for stale in connectedSources.subtracting(found) {
            MIDIPortDisconnectSource(inputPort, stale)
        }
        connectedSources = found

        destination = 0
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            if endpointMatches(dest) {
                destination = dest
                break
            }
        }

        if wasConnected != isConnected {
            Log.info("Grid \(isConnected ? "connected" : "disconnected")")
        }
        onStateChange(isConnected)
    }

    private func endpointMatches(_ endpoint: MIDIEndpointRef) -> Bool {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        guard let value = name?.takeRetainedValue() as String? else { return false }
        return value.localizedCaseInsensitiveContains(deviceName)
    }
}
