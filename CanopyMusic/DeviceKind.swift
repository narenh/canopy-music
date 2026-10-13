import CanopyMusicCore
import Foundation
import UIKit

/// What this device calls itself in copy. On an iPad, "iPad". Running on a Mac ("Designed for
/// iPad"), its kind of Mac ("MacBook Air", "iMac", …) from `hw.model`, or just "Mac" when that's
/// a model it doesn't know.
enum DeviceKind {
    #if DEBUG
    /// `-device MacBookAir` (any `MacKind` raw value): the simulator pretends to be that Mac, so
    /// a Mac hub or display can be looked at from another simulator.
    private static let override: MacKind? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-device"), i + 1 < args.count else { return nil }
        return MacKind(rawValue: args[i + 1]) ?? .mac
    }()
    #else
    private static let override: MacKind? = nil
    #endif

    static let isMac = override != nil || ProcessInfo.processInfo.isiOSAppOnMac

    /// Which Mac this is; nil on an iPad.
    static let macKind: MacKind? = override ?? (isMac ? macKind(model: sysctl("hw.model") ?? "") : nil)

    /// What goes on the wire (the TXT record, snapshots, the display hello): nil on an iPad.
    static var device: String? { macKind?.rawValue }

    /// "iPad", "MacBook Air", "MacBook Pro", "iMac", "Mac mini", "Mac Studio", "Mac Pro" or "Mac".
    static let noun: String = macKind?.noun ?? "iPad"

    /// The SF Symbol for this device: the same rule other devices use to draw it (`DeviceSymbol`).
    @MainActor static var symbol: String { DeviceSymbol.name(kind: .ipad, device: device) }

    /// This device's name for a new zone and for showing another zone as a display: the
    /// system's name on an iPad (which is just "iPad" without the device-name entitlement), the
    /// kind of Mac on a Mac.
    @MainActor static var name: String { isMac ? noun : UIDevice.current.name }

    /// The kind of Mac for a `hw.model` identifier: older identifiers name it ("MacBookAir10,1");
    /// newer ones are `MacNN,N` and need the table. Anything else is "Mac".
    static func macKind(model: String) -> MacKind {
        if let kind = currentModels[model] { return kind }
        let prefixes: [(String, MacKind)] = [("MacBookAir", .macBookAir), ("MacBookPro", .macBookPro), ("iMac", .iMac),
                                             ("Macmini", .macMini), ("MacPro", .macPro)]
        return prefixes.first { model.hasPrefix($0.0) }?.1 ?? .mac
    }

    /// Apple silicon `MacNN,N` identifiers. Only ones known for sure; the rest fall back to "Mac".
    private static let currentModels: [String: MacKind] = [
        // 2022–2023 (M1 Ultra/Max Studio, M2)
        "Mac13,1": .macStudio, "Mac13,2": .macStudio,
        "Mac14,2": .macBookAir, "Mac14,15": .macBookAir,
        "Mac14,7": .macBookPro, "Mac14,5": .macBookPro, "Mac14,6": .macBookPro,
        "Mac14,9": .macBookPro, "Mac14,10": .macBookPro,
        "Mac14,3": .macMini, "Mac14,12": .macMini,
        "Mac14,13": .macStudio, "Mac14,14": .macStudio,
        "Mac14,8": .macPro,
        // M3
        "Mac15,3": .macBookPro, "Mac15,6": .macBookPro, "Mac15,7": .macBookPro, "Mac15,8": .macBookPro,
        "Mac15,9": .macBookPro, "Mac15,10": .macBookPro, "Mac15,11": .macBookPro,
        "Mac15,4": .iMac, "Mac15,5": .iMac,
        "Mac15,12": .macBookAir, "Mac15,13": .macBookAir,
        // M4
        "Mac16,1": .macBookPro, "Mac16,5": .macBookPro, "Mac16,6": .macBookPro,
        "Mac16,7": .macBookPro, "Mac16,8": .macBookPro,
        "Mac16,2": .iMac, "Mac16,3": .iMac,
        "Mac16,10": .macMini, "Mac16,11": .macMini,
        "Mac16,12": .macBookAir, "Mac16,13": .macBookAir,
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
    @MainActor static func logRawValues() {
        print("[device] hw.model=\(sysctl("hw.model") ?? "nil") hw.machine=\(sysctl("hw.machine") ?? "nil") isiOSAppOnMac=\(isMac) noun=\(noun) symbol=\(symbol)")
    }
    #endif
}
