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
    private var lastAddress: String?
    private var lastPort: UInt16 = 0
    private var conflictRetries = 0

    /// `name` without the `.local` suffix, e.g. "music".
    public init(name: String) {
        hostname = "\(name).local"
    }

    /// Registers the A record, plus an `_http._tcp` service ("Canopy Music") on it so it shows up
    /// in Bonjour browsers. Returns false if mDNS refused the record outright; a name conflict
    /// (e.g. the previous launch's record still lingering) is retried a few times.
    @discardableResult
    public func register(address: String, port: UInt16) -> Bool {
        // Re-registering the same thing tears down a live record and probes again, which can
        // collide with the one just withdrawn. Keep it.
        if connection != nil, lastAddress == address, lastPort == port { return true }
        unregister()
        lastAddress = address
        lastPort = port
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
                    // Conflicts and policy denials arrive here, after the register call succeeded.
                    #if DEBUG
                    print("[mdns] register callback error=\(error)")
                    #endif
                    guard let context else { return }
                    let hostname = Unmanaged<FriendlyHostname>.fromOpaque(context).takeUnretainedValue()
                    hostname.registrationFinished(error: error)
                }, Unmanaged.passUnretained(self).toOpaque()
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

    /// Right after a relaunch the old process's record can still own the name, so the new one
    /// loses the conflict check. Try again shortly; it's usually gone within seconds.
    private func registrationFinished(error: DNSServiceErrorType) {
        // Callbacks arrive on `queue`; registration state is only touched on the main queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard error == kDNSServiceErr_NameConflict else {
                if error == kDNSServiceErr_NoError { self.conflictRetries = 0 }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // `lastAddress` is cleared by `unregister`, so a stopped server stays stopped.
                guard let self, let address = self.lastAddress, self.conflictRetries < 5 else { return }
                self.conflictRetries += 1
                let port = self.lastPort
                self.unregister()
                self.register(address: address, port: port)
            }
        }
    }

    public func unregister() {
        lastAddress = nil
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
