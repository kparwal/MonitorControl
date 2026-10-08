import Accelerate
import CoreAudio
import Foundation

/// Software volume for one output device.
///
/// Many monitors accept DDC volume writes but ignore them, and macOS offers no volume control
/// for Thunderbolt/DisplayPort audio. So: tap everything headed to the device (muting the
/// original), scale it, and play it back to the same device through a private aggregate.
/// Our own process is excluded from the tap, so the playback isn't re-captured.
///
/// The tap is owned by this process — if MonitorControl quits or crashes, macOS removes it and
/// audio flows to the monitor untouched again.
final class SoftVolume {
    let deviceUID: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let gainBox = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    /// Linear amplitude applied in the IO callback. Written from main, read on the audio thread;
    /// an aligned 32-bit store is atomic on arm64, which is all we need here.
    var gain: Float {
        get { gainBox.pointee }
        set { gainBox.pointee = newValue }
    }

    init(deviceUID: String, gain: Float) throws {
        self.deviceUID = deviceUID
        gainBox.initialize(to: gain)
        do { try start() } catch { stop(); gainBox.deallocate(); throw error }
    }

    deinit {
        stop()
        gainBox.deallocate()
    }

    private func start() throws {
        let me = try Self.ownProcessObject()
        let tap = CATapDescription(excludingProcesses: [me], deviceUID: deviceUID, stream: 0)
        tap.uuid = UUID()
        tap.name = "MonitorControl volume"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MonitorControl \(deviceUID)",
            kAudioAggregateDeviceUIDKey: "dev.monitorctl.agg.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")

        let gainPtr = gainBox
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Self.render(input: input, output: output, gain: gainPtr.pointee)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start device")
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Copy tap input → device output with gain, remapping channels if the layouts differ.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for (i, out) in outs.enumerated() {
            guard let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outCh = Int(max(out.mNumberChannels, 1))
            let outSamples = Int(out.mDataByteSize) / MemoryLayout<Float>.size
            guard i < ins.count, let src = ins[i].mData?.assumingMemoryBound(to: Float.self) else {
                vDSP_vclr(dst, 1, vDSP_Length(outSamples)); continue
            }
            let inCh = Int(max(ins[i].mNumberChannels, 1))
            let inSamples = Int(ins[i].mDataByteSize) / MemoryLayout<Float>.size
            var g = gain
            if inCh == outCh {
                let n = min(inSamples, outSamples)
                vDSP_vsmul(src, 1, &g, dst, 1, vDSP_Length(n))
                if n < outSamples { vDSP_vclr(dst + n, 1, vDSP_Length(outSamples - n)) }
            } else {
                let frames = min(inSamples / inCh, outSamples / outCh)
                vDSP_vclr(dst, 1, vDSP_Length(outSamples))
                for c in 0..<outCh {
                    // Interleaved: channel c of output takes channel min(c, inCh-1) of input.
                    vDSP_vsmul(src + min(c, inCh - 1), inCh, &g, dst + c, outCh, vDSP_Length(frames))
                }
            }
        }
    }

    /// Perceptual-ish curve: slider percent → linear amplitude.
    static func gain(percent: Int, muted: Bool) -> Float {
        muted ? 0 : powf(Float(min(max(percent, 0), 100)) / 100, 2)
    }

    private static func ownProcessObject() throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "translate pid")
        return object
    }
}

struct AudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (\(status))" }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw AudioError(what: what, status: status) }
}

/// Whether a CoreAudio device with this UID is currently present.
func audioDeviceExists(uid: String) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
    }
    return status == noErr && device != kAudioObjectUnknown
}
