import Foundation
import Observation

// Shared with the TV target (a symlink there).

/// Low Power Mode, followed live. While it's on, the animated art stops (the still art shows) and
/// the background stops drifting, so a hub iPad unplugged by accident lasts longer; the seek bar
/// and the equalizer carry on. Debug builds: `-lowPowerMode` turns it on at launch, and
/// `-lowPowerModeAfter <seconds>` a while after (the simulator has no Low Power Mode).
@MainActor @Observable
final class LowPowerMode {
    static let shared = LowPowerMode()

    private(set) var isOn = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LowPowerMode.shared.isOn = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-lowPowerMode") { isOn = true }
        if let i = args.firstIndex(of: "-lowPowerModeAfter"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                LowPowerMode.shared.isOn = true
            }
        }
        #endif
    }
}
