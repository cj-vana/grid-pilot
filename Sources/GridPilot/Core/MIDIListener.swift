import Foundation
import CoreMIDI

struct MIDIEvent: Equatable {
    var type: MIDIMessageType
    var number: Int
    var value: Int
    var channel: Int
}

/// Extracts a CC or note event from a MIDI 1.0 Universal MIDI Packet word.
/// UMP MIDI 1.0 channel voice: mt=2 in the top nibble, then group, status
/// byte, data1, data2. Grid pots/faders send CC; its buttons send notes, so
/// note on/off normalize to value = velocity / 0.
func parseEvent(word: UInt32) -> MIDIEvent? {
    let messageType = (word >> 28) & 0xF
    guard messageType == 2 else { return nil }
    let status = (word >> 16) & 0xFF
    let channel = Int(status & 0x0F)
    let number = Int((word >> 8) & 0x7F)
    let value = Int(word & 0x7F)
    switch status & 0xF0 {
    case 0xB0:
        return MIDIEvent(type: .cc, number: number, value: value, channel: channel)
    case 0x90:
        return MIDIEvent(type: .note, number: number, value: value, channel: channel)
    case 0x80:
        return MIDIEvent(type: .note, number: number, value: 0, channel: channel)
    default:
        return nil
    }
}

/// Connects to every CoreMIDI source whose device name contains `deviceName`,
/// reconnects when the device is replugged, and can send CCs back for LED
/// feedback.
final class MIDIListener {
    private let deviceName: String
    private let onEvent: (MIDIEvent) -> Void
    private let onStateChange: (Bool) -> Void
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connectedSources: Set<MIDIEndpointRef> = []
    private var destination: MIDIEndpointRef = 0

    init(
        deviceName: String,
        onEvent: @escaping (MIDIEvent) -> Void,
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
        send(type: .cc, number: cc, value: value, channel: channel)
    }

    func send(type: MIDIMessageType, number: Int, value: Int, channel: Int) {
        guard destination != 0 else { return }
        let status: UInt32 = type == .note ? 0x90 : 0xB0
        let word: UInt32 = (2 << 28) | (status | UInt32(channel & 0xF)) << 16 | UInt32(number & 0x7F) << 8 | UInt32(value & 0x7F)
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size, packet, 0, 1, [word])
        MIDISendEventList(outputPort, destination, &eventList)
    }

    var isConnected: Bool { !connectedSources.isEmpty }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        var events: [MIDIEvent] = []
        var packet = eventList.pointee.packet
        for _ in 0..<eventList.pointee.numPackets {
            let wordCount = Int(packet.wordCount)
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0..<min(wordCount, words.count) {
                    if let event = parseEvent(word: words[i]) {
                        events.append(event)
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [onEvent] in
            for event in events {
                onEvent(event)
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
