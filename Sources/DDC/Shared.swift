import Foundation

/// Glue between the `monitorctl` CLI and the MonitorControl menu bar app.
///
/// The monitors ignore DDC volume, so volume is applied in software by MonitorControl. The CLI
/// asks MonitorControl to change it via a distributed notification and reads the current values
/// from MonitorControl's defaults domain.
public enum Shared {
    public static let bundleID = "dev.monitorctl.MonitorControl"
    public static let volumeRequest = Notification.Name("dev.monitorctl.volumeRequest")

    /// MonitorControl's own defaults; from inside MonitorControl that's `.standard` (a suite named after
    /// your own bundle ID is rejected), from the CLI it's MonitorControl's domain.
    public static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == bundleID ? .standard : UserDefaults(suiteName: bundleID)!
    }

    public static func volumeKey(_ serial: UInt32) -> String { "volume.\(serial)" }
    public static func mutedKey(_ serial: UInt32) -> String { "muted.\(serial)" }

    /// userInfo keys for `volumeRequest`.
    public enum Key {
        public static let serial = "serial"     // String
        public static let value = "value"       // Int
        public static let relative = "relative" // Bool
        public static let mute = "mute"         // Bool (optional; overrides value)
    }

    public static var isAppRunning: Bool {
        // NSRunningApplication lives in AppKit; avoid pulling it into the CLI.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "MonitorControl"]
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
