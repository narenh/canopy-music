import Foundation
import UIKit

/// What this device calls itself in copy. On an iPad, "iPad". Running on a Mac ("Designed for
/// iPad"), its kind of Mac ("MacBook Air", "iMac", …) from `hw.model`, or just "Mac" when that's
/// a model it doesn't know.
enum DeviceKind {
    static let isMac = ProcessInfo.processInfo.isiOSAppOnMac

    /// "iPad", "MacBook Air", "MacBook Pro", "iMac", "Mac mini", "Mac Studio", "Mac Pro" or "Mac".
    static let noun: String = isMac ? macNoun(model: sysctl("hw.model") ?? "") : "iPad"

    /// The SF Symbol for this device.
    static let symbol: String = switch noun {
    case "iPad": "ipad.landscape"
    case "MacBook Air", "MacBook Pro": "laptopcomputer"
    case "Mac mini": "macmini"
    case "Mac Studio": "macstudio"
    case "Mac Pro": "macpro.gen3"
    default: "desktopcomputer"
    }

    /// This device's name for a new zone and for showing another zone as a display: the
    /// system's name on an iPad (which is just "iPad" without the device-name entitlement), the
    /// kind of Mac on a Mac.
    @MainActor static var name: String { isMac ? noun : UIDevice.current.name }

    /// The kind of Mac for a `hw.model` identifier: older identifiers name it ("MacBookAir10,1");
    /// newer ones are `MacNN,N` and need the table. Anything else is "Mac".
    static func macNoun(model: String) -> String {
        if let noun = currentModels[model] { return noun }
        let prefixes = [("MacBookAir", "MacBook Air"), ("MacBookPro", "MacBook Pro"), ("iMac", "iMac"),
                        ("Macmini", "Mac mini"), ("MacPro", "Mac Pro")]
        return prefixes.first { model.hasPrefix($0.0) }?.1 ?? "Mac"
    }

    /// Apple silicon `MacNN,N` identifiers. Only ones known for sure; the rest fall back to "Mac".
    private static let currentModels: [String: String] = [
        // 2022–2023 (M1 Ultra/Max Studio, M2)
        "Mac13,1": "Mac Studio", "Mac13,2": "Mac Studio",
        "Mac14,2": "MacBook Air", "Mac14,15": "MacBook Air",
        "Mac14,7": "MacBook Pro", "Mac14,5": "MacBook Pro", "Mac14,6": "MacBook Pro",
        "Mac14,9": "MacBook Pro", "Mac14,10": "MacBook Pro",
        "Mac14,3": "Mac mini", "Mac14,12": "Mac mini",
        "Mac14,13": "Mac Studio", "Mac14,14": "Mac Studio",
        "Mac14,8": "Mac Pro",
        // M3
        "Mac15,3": "MacBook Pro", "Mac15,6": "MacBook Pro", "Mac15,7": "MacBook Pro", "Mac15,8": "MacBook Pro",
        "Mac15,9": "MacBook Pro", "Mac15,10": "MacBook Pro", "Mac15,11": "MacBook Pro",
        "Mac15,4": "iMac", "Mac15,5": "iMac",
        "Mac15,12": "MacBook Air", "Mac15,13": "MacBook Air",
        // M4
        "Mac16,1": "MacBook Pro", "Mac16,5": "MacBook Pro", "Mac16,6": "MacBook Pro",
        "Mac16,7": "MacBook Pro", "Mac16,8": "MacBook Pro",
        "Mac16,2": "iMac", "Mac16,3": "iMac",
        "Mac16,10": "Mac mini", "Mac16,11": "Mac mini",
        "Mac16,12": "MacBook Air", "Mac16,13": "MacBook Air",
    ]

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    #if DEBUG
    /// What `hw.model` says for an iOS app on a Mac isn't known yet (the real Mac's identifier,
    /// or a stand-in iPad one); this shows it in Xcode's console.
    static func logRawValues() {
        print("[device] hw.model=\(sysctl("hw.model") ?? "nil") hw.machine=\(sysctl("hw.machine") ?? "nil") isiOSAppOnMac=\(isMac) noun=\(noun)")
    }
    #endif
}
