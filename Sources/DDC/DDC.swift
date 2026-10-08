import CoreGraphics
import Foundation
import IOKit

/// MCCS VCP codes we care about.
public enum VCP: UInt8, CaseIterable, Sendable {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    case mute = 0x8D

    public init?(name: String) {
        switch name.lowercased() {
        case "brightness", "b", "luminance": self = .brightness
        case "contrast", "c": self = .contrast
        case "volume", "v", "vol": self = .volume
        case "mute", "m": self = .mute
        default: return nil
        }
    }

    public var name: String { String(describing: self) }
}

public enum DDCError: Error, CustomStringConvertible {
    case writeFailed(IOReturn)
    case readFailed(IOReturn)
    case badReply([UInt8])
    case unsupported(VCP)

    public var description: String {
        switch self {
        case .writeFailed(let r): return "I2C write failed (0x\(String(UInt32(bitPattern: r), radix: 16)))"
        case .readFailed(let r): return "I2C read failed (0x\(String(UInt32(bitPattern: r), radix: 16)))"
        case .badReply(let b): return "bad DDC reply: \(b.map { String(format: "%02x", $0) }.joined(separator: " "))"
        case .unsupported(let v): return "monitor reports \(v.name) as unsupported"
        }
    }
}

public struct VCPValue: Sendable {
    public let current: UInt16
    public let max: UInt16
}

/// One external display reachable over DDC/CI.
public final class Display: @unchecked Sendable {
    public let index: Int
    public let name: String
    public let serial: UInt32
    public let displayID: CGDirectDisplayID?
    /// CoreAudio device UID of this monitor's speakers (Thunderbolt/DP audio), if any.
    public let audioDeviceUID: String?
    let service: IOAVServiceRef
    private let lock = NSLock()

    init(index: Int, name: String, serial: UInt32, displayID: CGDirectDisplayID?,
         audioDeviceUID: String?, service: IOAVServiceRef) {
        self.index = index
        self.name = name
        self.serial = serial
        self.displayID = displayID
        self.audioDeviceUID = audioDeviceUID
        self.service = service
    }

    public var isMain: Bool { displayID.map { CGDisplayIsMain($0) != 0 } ?? false }
    public var rotation: Int { displayID.map { Int(CGDisplayRotation($0)) } ?? 0 }
    public var isPortrait: Bool { rotation == 90 || rotation == 270 }

    /// Short human label, e.g. "landscape · main" — handy because both monitors share a model name.
    public var label: String {
        var parts = [isPortrait ? "portrait" : "landscape"]
        if isMain { parts.append("main") }
        return parts.joined(separator: " · ")
    }

    // MARK: DDC/CI

    private static let chip: UInt32 = 0x37      // DDC/CI 7-bit address
    private static let hostAddr: UInt32 = 0x51  // source address byte
    private static let retries = 5

    public func set(_ vcp: VCP, _ value: UInt16) throws {
        var packet: [UInt8] = [0x84, 0x03, vcp.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(Self.checksum(seed: 0x6E ^ UInt8(Self.hostAddr), packet))
        try lock.withLock {
            var last: IOReturn = kIOReturnSuccess
            for _ in 0..<Self.retries {
                last = packet.withUnsafeBytes {
                    IOAVServiceWriteI2C(service, Self.chip, Self.hostAddr, $0.baseAddress!, UInt32($0.count))
                }
                if last == kIOReturnSuccess { usleep(10_000); return }
                usleep(20_000)
            }
            throw DDCError.writeFailed(last)
        }
    }

    public func get(_ vcp: VCP) throws -> VCPValue {
        var request: [UInt8] = [0x82, 0x01, vcp.rawValue]
        request.append(Self.checksum(seed: 0x6E ^ UInt8(Self.hostAddr), request))
        return try lock.withLock {
            var lastError: Error = DDCError.badReply([])
            for _ in 0..<Self.retries {
                let w = request.withUnsafeBytes {
                    IOAVServiceWriteI2C(service, Self.chip, Self.hostAddr, $0.baseAddress!, UInt32($0.count))
                }
                guard w == kIOReturnSuccess else { lastError = DDCError.writeFailed(w); usleep(20_000); continue }
                usleep(40_000) // MCCS: host must wait >= 40ms before reading the reply
                var reply = [UInt8](repeating: 0, count: 11)
                let r = reply.withUnsafeMutableBytes {
                    IOAVServiceReadI2C(service, Self.chip, Self.hostAddr, $0.baseAddress!, UInt32($0.count))
                }
                guard r == kIOReturnSuccess else { lastError = DDCError.readFailed(r); usleep(20_000); continue }
                // 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
                let sum = Self.checksum(seed: 0x50, Array(reply[0..<10]))
                guard reply[2] == 0x02, reply[4] == vcp.rawValue, sum == reply[10] else {
                    lastError = DDCError.badReply(reply); usleep(20_000); continue
                }
                if reply[3] != 0 { throw DDCError.unsupported(vcp) }
                return VCPValue(current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                                max: UInt16(reply[6]) << 8 | UInt16(reply[7]))
            }
            throw lastError
        }
    }

    private static func checksum(seed: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed, ^)
    }
}

// MARK: Discovery

public enum Displays {
    /// Finds every external display with a DCP AV service, paired with its CGDirectDisplayID.
    ///
    /// Walks the IOService plane in order: each framebuffer node carrying `DisplayAttributes`
    /// (EDID-derived name/serial) is followed by the `DCPAVServiceProxy` that drives its port.
    /// This works for daisy-chained Thunderbolt displays too — each gets its own proxy.
    public static func discover() -> [Display] {
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var pendingAttrs: (name: String, serial: UInt32)?
        var found: [(name: String, serial: UInt32, audioUID: String?, service: IOAVServiceRef)] = []

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let attrs = property(entry, "DisplayAttributes") as? [String: Any],
               let product = attrs["ProductAttributes"] as? [String: Any] {
                pendingAttrs = (product["ProductName"] as? String ?? "Display",
                                (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0)
                continue
            }
            guard className(entry) == "DCPAVServiceProxy",
                  property(entry, "Location") as? String == "External",
                  let attrs = pendingAttrs,
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { continue }
            found.append((attrs.name, attrs.serial, audioUID(near: entry), av))
            pendingAttrs = nil
        }

        let online = onlineDisplays()
        let displays = found.map { f -> (String, UInt32, CGDirectDisplayID?, String?, IOAVServiceRef) in
            let id = online.first { CGDisplaySerialNumber($0) == f.serial && f.serial != 0 }
            return (f.name, f.serial, id, f.audioUID, f.service)
        }
        // Stable, intuitive order: main display first, then left-to-right on screen.
        .sorted { a, b in
            let am = a.2.map { CGDisplayIsMain($0) != 0 } ?? false
            let bm = b.2.map { CGDisplayIsMain($0) != 0 } ?? false
            if am != bm { return am }
            let ax = a.2.map { CGDisplayBounds($0).minX } ?? .infinity
            let bx = b.2.map { CGDisplayBounds($0).minX } ?? .infinity
            return ax < bx
        }
        return displays.enumerated().map { i, d in
            Display(index: i + 1, name: d.0, serial: d.1, displayID: d.2, audioDeviceUID: d.3, service: d.4)
        }
    }

    /// Identical monitors share an EDID UUID, so the audio device can't be matched by name.
    /// Instead, climb from the AV service proxy to the DCP that owns it; that DCP's subtree
    /// also holds the DCPAVAudioDriver for the same port, which publishes the CoreAudio UID.
    private static func audioUID(near proxy: io_registry_entry_t) -> String? {
        var current = proxy
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<10 {
            var parent = io_registry_entry_t()
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
            if let uid = IORegistryEntrySearchCFProperty(current, kIOServicePlane, "device UID" as CFString,
                                                         kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String {
                return uid
            }
        }
        return nil
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func className(_ entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buf)
        return String(cString: buf)
    }
}
