import dnssd
import Foundation

/// Announces `<name>.local` over mDNS pointing at this device's LAN address, so guests can type
/// a friendly URL. iPhones and Macs resolve `.local` names; some Android phones don't, which is
/// why the QR code always uses the raw IP.
public final class FriendlyHostname: @unchecked Sendable {
    public let hostname: String
    private var connection: DNSServiceRef?
    private var record: DNSRecordRef?
    private var service: DNSServiceRef?
    private let queue = DispatchQueue(label: "canopy.mdns")

    /// `name` without the `.local` suffix, e.g. "music".
    public init(name: String) {
        hostname = "\(name).local"
    }

    /// Registers the A record, plus an `_http._tcp` service ("Canopy Music") on it. Advertising a
    /// Bonjour service is what makes iPadOS ask for Local Network permission; without it the
    /// bare A record is silently blocked. Returns false if mDNS refused the record.
    @discardableResult
    public func register(address: String, port: UInt16) -> Bool {
        unregister()
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
                { _, _, _, error, _ in
                    // Conflicts and policy denials (Local Network permission) arrive here, after
                    // the register call itself succeeded.
                    #if DEBUG
                    print("[mdns] register callback error=\(error)")
                    #endif
                }, nil
            )
        }
        #if DEBUG
        print("[mdns] register \(hostname) -> \(address) status=\(status)")
        #endif
        guard status == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return false
        }
        DNSServiceSetDispatchQueue(connection, queue)
        self.connection = connection
        self.record = record

        var service: DNSServiceRef?
        let serviceStatus = DNSServiceRegister(
            &service, 0, 0, "Canopy Music", "_http._tcp", nil, hostname + ".", port.bigEndian, 0, nil,
            { _, _, error, name, _, _, _ in
                #if DEBUG
                print("[mdns] service callback error=\(error) name=\(name.map { String(cString: $0) } ?? "?")")
                #endif
            }, nil
        )
        if serviceStatus == kDNSServiceErr_NoError, let service {
            DNSServiceSetDispatchQueue(service, queue)
            self.service = service
        }
        return true
    }

    public func unregister() {
        if let service {
            DNSServiceRefDeallocate(service)
        }
        service = nil
        if let connection {
            DNSServiceRefDeallocate(connection)
        }
        connection = nil
        record = nil
    }

    deinit { unregister() }
}
