import AppKit
import CoreGraphics
import DDC
import ServiceManagement

/// Serialises DDC writes for one display and drops intermediate values, so dragging a
/// slider never queues up a backlog of slow I2C transactions.
final class Coalescer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: UInt16?
    private var busy = false
    private let write: (UInt16) -> Void

    init(label: String, write: @escaping (UInt16) -> Void) {
        queue = DispatchQueue(label: label)
        self.write = write
    }

    func submit(_ value: UInt16) {
        lock.lock()
        pending = value
        guard !busy else { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard let v = pending else { busy = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                write(v)
            }
        }
    }
}

@MainActor
final class Monitor: ObservableObject, Identifiable {
    let display: Display
    nonisolated var id: UInt32 { display.serial }
    @Published var brightness: Double = 50
    @Published var volume: Double
    @Published var muted: Bool
    @Published var audioError: String?

    fileprivate var engine: SoftVolume?
    fileprivate lazy var brightnessWriter = Coalescer(label: "ddc.\(display.serial)") { [display] v in
        try? display.set(.brightness, v)
    }

    init(display: Display) {
        self.display = display
        let d = Shared.defaults
        volume = d.object(forKey: Shared.volumeKey(display.serial)) as? Double ?? 100
        muted = d.bool(forKey: Shared.mutedKey(display.serial))
    }

    var title: String { "\(display.name) — \(display.label)" }
    var hasAudio: Bool { display.audioDeviceUID != nil }
}

@MainActor
final class Model: ObservableObject {
    @Published private(set) var monitors: [Monitor] = []
    @Published var linked: Bool { didSet { Shared.defaults.set(linked, forKey: "linked") } }
    @Published private(set) var permission: AudioPermission.State = AudioPermission.state
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("login item: \(error)") }
        }
    }

    private var reloadWork: DispatchWorkItem?

    init() {
        linked = Shared.defaults.object(forKey: "linked") as? Bool ?? true
        reload()
        observeSystem()
    }

    // MARK: Discovery

    func reload() {
        for m in monitors { m.engine = nil }
        monitors = Displays.discover().map(Monitor.init)
        refreshBrightness()
        for m in monitors { applyVolume(m) }
    }

    func refreshBrightness() {
        for m in monitors {
            let display = m.display
            DispatchQueue.global(qos: .userInitiated).async {
                guard let v = try? display.get(.brightness), v.max > 0 else { return }
                let pct = Double(v.current) / Double(v.max) * 100
                DispatchQueue.main.async { m.brightness = pct.rounded() }
            }
        }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Brightness

    func setBrightness(_ value: Double, from source: Monitor) {
        for m in targets(source) {
            m.brightness = value
            m.brightnessWriter.submit(UInt16(value.rounded()))
        }
    }

    // MARK: Volume

    func setVolume(_ value: Double, from source: Monitor) {
        for m in targets(source) where m.hasAudio {
            m.volume = value.rounded()
            if value > 0 { m.muted = false }
            persist(m)
            applyVolume(m)
        }
    }

    func toggleMute(_ source: Monitor) {
        let muted = !source.muted
        for m in targets(source) where m.hasAudio {
            m.muted = muted
            persist(m)
            applyVolume(m)
        }
    }

    func requestPermission() {
        AudioPermission.request { [weak self] _ in
            guard let self else { return }
            permission = AudioPermission.state
            for m in monitors { applyVolume(m) }
        }
    }

    private func targets(_ source: Monitor) -> [Monitor] { linked ? monitors : [source] }

    private func persist(_ m: Monitor) {
        Shared.defaults.set(m.volume, forKey: Shared.volumeKey(m.id))
        Shared.defaults.set(m.muted, forKey: Shared.mutedKey(m.id))
    }

    /// Engage the software volume tap only when it's actually attenuating; at 100% and
    /// unmuted, audio takes the native path with zero added latency.
    private func applyVolume(_ m: Monitor) {
        guard let uid = m.display.audioDeviceUID else { return }
        let gain = SoftVolume.gain(percent: Int(m.volume), muted: m.muted)
        if gain >= 1 { m.engine = nil; m.audioError = nil; return }

        permission = AudioPermission.state
        guard permission == .granted else {
            m.engine = nil
            if permission == .unknown { requestPermission() }
            m.audioError = permission == .denied ? "Allow System Audio Recording for MonitorControl" : nil
            return
        }
        if let engine = m.engine { engine.gain = gain; return }
        guard audioDeviceExists(uid: uid) else { m.audioError = "audio device not found"; return }
        do {
            m.engine = try SoftVolume(deviceUID: uid, gain: gain)
            m.audioError = nil
        } catch {
            m.audioError = "\(error)"
        }
    }

    // MARK: System events & CLI

    private func observeSystem() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            let model = Unmanaged<Model>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { model.scheduleReload() }
        }, ctx)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }

        DistributedNotificationCenter.default().addObserver(forName: Shared.volumeRequest, object: nil,
                                                            queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handleCLI(info) }
        }
    }

    private func handleCLI(_ info: [AnyHashable: Any]) {
        let serial = info[Shared.Key.serial] as? String
        let targets = monitors.filter { serial == nil || String($0.id) == serial }
        for m in targets where m.hasAudio {
            if let mute = info[Shared.Key.mute] as? Bool {
                m.muted = mute
            } else if let value = info[Shared.Key.value] as? Int {
                let relative = info[Shared.Key.relative] as? Bool ?? false
                m.volume = Double(min(100, max(0, relative ? Int(m.volume) + value : value)))
                m.muted = false
            }
            persist(m)
            applyVolume(m)
        }
    }
}
