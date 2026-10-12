import dnssd
import Foundation

/// Announces `<name>.local` over mDNS pointing at this device's LAN address, so guests can type
/// a friendly URL. iPhones and Macs resolve `.local` names; some Android phones don't, which is
/// why the QR code always uses the raw IP.
///
/// Several zones can share a network, so if the name is taken this tries once more (a just-closed
/// copy of the app can hold it for a few seconds), then moves on to `name-2`, `name-3`… and calls
/// `onRename` so the app can update what it shows.
public final class FriendlyHostname: @unchecked Sendable {
    public private(set) var hostname: String
    /// Called on the main queue with the new hostname after a clash moved it.
    public var onRename: (@MainActor @Sendable (String) -> Void)?

    private let baseName: String
    private var suffix = 1
    private var retriedBase = false
    private var address: String?
    private var connection: DNSServiceRef?
    private var record: DNSRecordRef?
    private let queue = DispatchQueue(label: "canopy.mdns")

    /// `name` without the `.local` suffix, e.g. "music".
    public init(name: String) {
        baseName = name
        hostname = "\(name).local"
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
                    guard error == kDNSServiceErr_NameConflict, let context else { return }
                    let owner = Unmanaged<FriendlyHostname>.fromOpaque(context).takeUnretainedValue()
                    DispatchQueue.main.async { owner.nameTaken() }
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
        hostname = "\(baseName)-\(suffix).local"
        register(address: address)
        let name = hostname
        if let onRename {
            MainActor.assumeIsolated { onRename(name) }
        }
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
