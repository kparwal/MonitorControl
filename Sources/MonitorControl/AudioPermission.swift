import Foundation

/// "System Audio Recording" permission (TCC service kTCCServiceAudioCapture).
///
/// Process taps need it, and without it a muted tap would deliver silence — so we must
/// know it's granted before engaging. There's no public API to query it; this uses the
/// same TCC SPI that Apple's own sample-adjacent tools (e.g. AudioCap) rely on.
enum AudioPermission {
    enum State { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var state: State {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { completion(false); return }
        unsafeBitCast(sym, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
