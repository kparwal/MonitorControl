import DDC
import Foundation

let usage = """
usage: monitorctl <command> [args]

  list                              show detected displays and their values
  get <control> [display]           print current value (0-100)
  set <control> <value> [display]   set value; value may be N, +N or -N
  mute|unmute [display]             mute or unmute speakers

  Volume is applied in software by MonitorControl.app (the monitors ignore DDC
  volume), so volume/mute commands need MonitorControl running.

  control:  brightness (b) | volume (v) | contrast (c)
  display:  1, 2, ... | all (default) | main | portrait | landscape | <serial>

examples:
  monitorctl set b 70            # both monitors to 70% brightness
  monitorctl set v +10 portrait  # bump the rotated monitor's volume
  monitorctl get brightness 2
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func select(_ displays: [Display], _ selector: String?) -> [Display] {
    guard let s = selector?.lowercased(), s != "all" else { return displays }
    let picked: [Display]
    switch s {
    case "main": picked = displays.filter(\.isMain)
    case "portrait": picked = displays.filter(\.isPortrait)
    case "landscape": picked = displays.filter { !$0.isPortrait }
    default:
        if let n = Int(s), n >= 1, n <= displays.count { picked = [displays[n - 1]] }
        else { picked = displays.filter { String($0.serial) == s } }
    }
    if picked.isEmpty { fail("no display matches '\(selector!)'. Try `monitorctl list`.") }
    return picked
}

func control(_ arg: String?) -> VCP {
    guard let arg, let vcp = VCP(name: arg) else { fail("unknown control '\(arg ?? "")'\n\n\(usage)") }
    return vcp
}

/// Volume lives in MonitorControl (software volume); the monitors ignore DDC volume writes.
func softVolume(_ d: Display) -> String {
    guard d.audioDeviceUID != nil else { return "n/a" }
    let defaults = Shared.defaults
    if defaults.bool(forKey: Shared.mutedKey(d.serial)) { return "muted" }
    let v = defaults.object(forKey: Shared.volumeKey(d.serial)) as? Double ?? 100
    return "\(Int(v))"
}

func requestVolume(_ targets: [Display], all: Bool, value: Int? = nil, relative: Bool = false, mute: Bool? = nil) {
    guard Shared.isAppRunning else { fail("volume is applied by MonitorControl — launch MonitorControl.app first") }
    let serials: [String?] = all ? [nil] : targets.map { String($0.serial) }
    for serial in serials {
        var info: [String: Any] = [:]
        if let serial { info[Shared.Key.serial] = serial }
        if let value { info[Shared.Key.value] = value; info[Shared.Key.relative] = relative }
        if let mute { info[Shared.Key.mute] = mute }
        DistributedNotificationCenter.default().postNotificationName(
            Shared.volumeRequest, object: nil, userInfo: info, deliverImmediately: true)
    }
    for d in targets {
        let what = mute.map { $0 ? "muted" : "unmuted" }
            ?? "volume → \(relative ? (value! >= 0 ? "+" : "") : "")\(value!)"
        print("[\(d.index)] \(what)")
    }
}

func isAll(_ selector: String?) -> Bool { selector == nil || selector!.lowercased() == "all" }

func percent(_ v: VCPValue) -> Int {
    v.max == 0 ? Int(v.current) : Int((Double(v.current) / Double(v.max) * 100).rounded())
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

let displays = Displays.discover()
if displays.isEmpty && command != "help" { fail("no external DDC displays found") }

switch command {
case "list", "ls":
    for d in displays {
        let b = (try? d.get(.brightness)).map { "\(percent($0))%" } ?? "n/a"
        print("[\(d.index)] \(d.name)  serial \(d.serial)  (\(d.label))  brightness \(b)  volume \(softVolume(d))")
        if ProcessInfo.processInfo.environment["MONITORCTL_DEBUG"] != nil {
            print("    display id \(d.displayID.map(String.init) ?? "?")  audio \(d.audioDeviceUID ?? "none")")
        }
    }

case "get":
    let vcp = control(args.first)
    let targets = select(displays, args.dropFirst().first)
    for d in targets {
        if vcp == .volume {
            print(targets.count > 1 ? "[\(d.index)] \(softVolume(d))" : softVolume(d)); continue
        }
        do {
            let v = try d.get(vcp)
            print(targets.count > 1 ? "[\(d.index)] \(percent(v))" : "\(percent(v))")
        } catch { fail("[\(d.index)] \(error)") }
    }

case "set":
    let vcp = control(args.first)
    guard args.count >= 2 else { fail(usage) }
    let raw = args[1]
    guard let amount = Int(raw) else { fail("bad value '\(raw)'") }
    let relative = raw.hasPrefix("+") || raw.hasPrefix("-")
    let selector = args.dropFirst(2).first
    if vcp == .volume {
        requestVolume(select(displays, selector), all: isAll(selector), value: amount, relative: relative)
        exit(0)
    }
    var failed = false
    for d in select(displays, args.dropFirst(2).first) {
        do {
            var target = amount
            var maxValue = 100
            if relative || vcp != .brightness && vcp != .volume && vcp != .contrast {
                let cur = try d.get(vcp)
                maxValue = Int(cur.max)
                target = relative ? percent(cur) + amount : amount
            }
            target = min(100, max(0, target))
            let rawValue = UInt16((Double(target) / 100 * Double(maxValue)).rounded())
            try d.set(vcp, rawValue)
            print("[\(d.index)] \(vcp.name) → \(target)")
        } catch { failed = true; FileHandle.standardError.write("[\(d.index)] \(error)\n".data(using: .utf8)!) }
    }
    if failed { exit(1) }

case "mute", "unmute":
    requestVolume(select(displays, args.first), all: isAll(args.first), mute: command == "mute")

case "help", "-h", "--help":
    print(usage)

default:
    fail(usage)
}
