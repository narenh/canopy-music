import Foundation

public enum LocalNetwork {
    /// The device's IPv4 address on Wi-Fi (or Ethernet), e.g. "192.168.1.23".
    public static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates[name] = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        for name in ["en0", "en1", "en2", "bridge100"] {
            if let address = candidates[name] { return address }
        }
        return candidates.first { !$0.key.hasPrefix("lo") && !$0.value.hasPrefix("169.254") }?.value
    }

    /// Payload for a QR code that joins a Wi-Fi network.
    public static func wifiJoinPayload(ssid: String, password: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: ":", with: "\\:")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let security = password.isEmpty ? "nopass" : "WPA"
        return "WIFI:T:\(security);S:\(escape(ssid));P:\(escape(password));;"
    }
}
