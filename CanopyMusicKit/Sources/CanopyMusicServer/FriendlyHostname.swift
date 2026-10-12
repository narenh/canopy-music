import dnssd
import Foundation

/// Announces `<name>.local` over mDNS pointing at this device's LAN address, so guests can type
/// a friendly URL. iPhones and Macs resolve `.local` names; some Android phones don't, which is
/// why the QR code always uses the raw IP.
///
/// Several zones can share a network, so if the name is taken this tries once more (a just-closed
/// copy of the app can hold it for a few seconds), then moves on to `name-2`, `name-3`….
///
/// Only hand the name out once `onConfirmed` reports it: until mDNS has checked, another device
/// may own it, and guests sent there reach the wrong zone.
///
/// Each hub's name follows its zone name (`localName(forZone:)`): "Living Room" is
/// `living-room.local`.
public final class FriendlyHostname: @unchecked Sendable {
    public private(set) var hostname: String
    /// Called on the main queue with the hostname once it's confirmed ours (again after a clash
    /// moves it to `name-2` and so on).
    public var onConfirmed: (@MainActor @Sendable (String) -> Void)?

    private var baseName: String
    private var suffix = 1
    private var retriedBase = false
    private var address: String?
    private var connection: DNSServiceRef?
    private var record: DNSRecordRef?
    private let queue = DispatchQueue(label: "canopymusic.mdns")

    /// `name` without the `.local` suffix, e.g. "music".
    public init(name: String) {
        baseName = name
        hostname = "\(name).local"
    }

    /// The `.local` name (without `.local`) for a zone: lowercase letters, digits and hyphens, at
    /// most 63 characters, `music` if nothing's left. Simulator builds prefix `canopytest-`, so
    /// test zones never claim real names on the network.
    public static func localName(forZone zoneName: String?) -> String {
        let name = slug(zoneName ?? "")
        #if targetEnvironment(simulator)
        return slug("canopytest-" + name)
        #else
        return name
        #endif
    }

    /// "Naren's Living Room" → "narens-living-room"; "Café" → "cafe"; "" → "music".
    static func slug(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var name = ""
        for character in raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() {
            if allowed.contains(character) {
                name.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue // "Naren's" reads better as "narens" than "naren-s"
            } else if !name.isEmpty, name.last != "-" {
                name.append("-")
            }
        }
        name = String(name.prefix(63))
        while name.hasSuffix("-") { name.removeLast() }
        return name.isEmpty ? "music" : name
    }

    /// Moves to a new name (the zone was renamed): drops the old one and, if it was announced,
    /// announces the new one. `onConfirmed` reports it once it's ours.
    /// Returns false if it already had that name.
    @discardableResult
    public func rename(to name: String) -> Bool {
        guard name != baseName else { return false }
        let wasRegistered = connection != nil
        unregister()
        baseName = name
        suffix = 1
        retriedBase = false
        hostname = "\(name).local"
        if wasRegistered, let address { register(address: address) }
        return true
    }

    /// Registers the A record. Returns false if mDNS refused outright (no permission, bad address).
    @discardableResult
    public func register(address: String) -> Bool {
        unregister()
        self.address = address
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else { return false }

        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else { return false }

        var record: DNSRecordRef?
        let status = withUnsafeBytes(of: &addr) { bytes in
            DNSServiceRegisterRecord(
                connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), 0,
                hostname + ".", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                UInt16(bytes.count), bytes.baseAddress, 120,
                { _, _, _, error, context in
                    guard let context else { return }
                    let owner = Unmanaged<FriendlyHostname>.fromOpaque(context).takeUnretainedValue()
                    if error == kDNSServiceErr_NoError {
                        DispatchQueue.main.async { owner.nameConfirmed() }
                    } else if error == kDNSServiceErr_NameConflict {
                        DispatchQueue.main.async { owner.nameTaken() }
                    }
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard status == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return false
        }
        DNSServiceSetDispatchQueue(connection, queue)
        self.connection = connection
        self.record = record
        return true
    }

    private func nameConfirmed() {
        guard connection != nil else { return }
        let name = hostname
        if let onConfirmed {
            MainActor.assumeIsolated { onConfirmed(name) }
        }
    }

    private func nameTaken() {
        guard let address, connection != nil else { return }
        if suffix == 1, !retriedBase {
            retriedBase = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.connection != nil else { return }
                self.register(address: address)
            }
            return
        }
        guard suffix < 9 else { return }
        suffix += 1
        // A DNS label is at most 63 characters, suffix included.
        hostname = "\(baseName.prefix(63 - 2))-\(suffix).local"
        register(address: address)
    }

    public func unregister() {
        if let connection {
            DNSServiceRefDeallocate(connection)
        }
        connection = nil
        record = nil
    }

    deinit { unregister() }
}
