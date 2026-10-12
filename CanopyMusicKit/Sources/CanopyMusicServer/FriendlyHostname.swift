import dnssd
import Foundation

/// Announces `<name>.local` over mDNS pointing at this device's LAN address, so guests can type
/// a friendly URL. iPhones and Macs resolve `.local` names; some Android phones don't, which is
/// why the QR code always uses the raw IP.
///
/// Several zones can share a network, so if the name is taken this tries once more (a just-closed
/// copy of the app can hold it for a few seconds), then moves on to `name-2`, `name-3`….
///
/// The one taken name that's fine is this device's own: an Apple TV called "Living Room" is
/// already `Living-Room.local`, so a zone named after its room would always clash with the device
/// itself. When the name already resolves to this device's address, it's used as it is.
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
    private var checkedOwnName = false
    /// The name is the device's own (no record of ours needed).
    private var usingOwnName = false
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
        let wasRegistered = connection != nil || usingOwnName
        unregister()
        baseName = name
        hostname = "\(name).local"
        if wasRegistered, let address { register(address: address) }
        return true
    }

    /// Registers the A record for the zone's name. Returns false if mDNS refused outright (no
    /// permission, bad address).
    @discardableResult
    public func register(address: String) -> Bool {
        suffix = 1
        retriedBase = false
        checkedOwnName = false
        hostname = "\(baseName).local"
        return announce(address: address)
    }

    private func announce(address: String) -> Bool {
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
        if suffix == 1, !checkedOwnName {
            // Taken by this very device (its own name, on any of its interfaces; the system
            // answers for itself with loopback too)? Then it already leads here.
            checkedOwnName = true
            let name = hostname
            let own = Set(LocalNetwork.ipv4Addresses().values)
            Self.addresses(of: name, on: queue) { [weak self] found in
                guard let self, self.connection != nil, self.hostname == name else { return }
                if !own.isDisjoint(with: found) {
                    self.useOwnName()
                } else {
                    self.nameTaken()
                }
            }
            return
        }
        if suffix == 1, !retriedBase {
            retriedBase = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.connection != nil else { return }
                _ = self.announce(address: address)
            }
            return
        }
        guard suffix < 9 else { return }
        suffix += 1
        // A DNS label is at most 63 characters, suffix included.
        hostname = "\(baseName.prefix(63 - 2))-\(suffix).local"
        _ = announce(address: address)
    }

    /// The name is this device's own, so it needs no record of ours: hand it out as it is.
    private func useOwnName() {
        unregister()
        usingOwnName = true
        let name = hostname
        if let onConfirmed {
            MainActor.assumeIsolated { onConfirmed(name) }
        }
    }

    /// The IPv4 addresses `name` resolves to over mDNS, gathered for up to `timeout` seconds
    /// (fewer if this device's own records answer at once). Calls back on the main queue.
    static func addresses(of name: String, on queue: DispatchQueue, timeout: TimeInterval = 2,
                          completion: @escaping @Sendable ([String]) -> Void) {
        final class Lookup: @unchecked Sendable {
            var ref: DNSServiceRef?
            var found: [String] = []
            var finished = false
            let queue: DispatchQueue
            let completion: @Sendable ([String]) -> Void
            init(queue: DispatchQueue, completion: @escaping @Sendable ([String]) -> Void) {
                self.queue = queue
                self.completion = completion
            }
            /// On `queue`. Releases the lookup's own retain.
            func finish() {
                guard !finished else { return }
                finished = true
                if let ref { DNSServiceRefDeallocate(ref) }
                ref = nil
                let found = found
                DispatchQueue.main.async { self.completion(found) }
                Unmanaged.passUnretained(self).release()
            }
        }
        let lookup = Lookup(queue: queue, completion: completion)
        _ = Unmanaged.passRetained(lookup) // released by finish()
        queue.async {
            let context = Unmanaged.passUnretained(lookup).toOpaque()
            var ref: DNSServiceRef?
            let status = DNSServiceGetAddrInfo(
                &ref, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4), name,
                { _, flags, _, error, _, address, _, context in
                    guard let context else { return }
                    let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
                    guard !lookup.finished, error == kDNSServiceErr_NoError, let address,
                          address.pointee.sa_family == sa_family_t(AF_INET) else { return }
                    var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &ip, &text, socklen_t(text.count)) != nil {
                        lookup.found.append(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                    }
                    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0, lookup.found.count > 0 {
                        // Keep listening briefly for other answers (other interfaces), then stop.
                        lookup.queue.asyncAfter(deadline: .now() + 0.5) { lookup.finish() }
                    }
                },
                context
            )
            guard status == kDNSServiceErr_NoError, let ref else {
                lookup.finish()
                return
            }
            lookup.ref = ref
            DNSServiceSetDispatchQueue(ref, queue)
            queue.asyncAfter(deadline: .now() + timeout) { lookup.finish() }
        }
    }

    public func unregister() {
        if let connection {
            DNSServiceRefDeallocate(connection)
        }
        connection = nil
        record = nil
        usingOwnName = false
    }

    deinit { unregister() }
}
