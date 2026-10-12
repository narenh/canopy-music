import Foundation
import Observation
import Security

/// Host Control on a hub (iPad or Apple TV): the key in the host QR code, and the phones that have
/// used it. Both are kept across launches, so a host stays a host when the hub restarts.
@MainActor
@Observable
public final class HostControl {
    public private(set) var key: String
    /// Client IDs of phones that have used the key.
    public private(set) var phones: [String]
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = defaults.string(forKey: "hostControlKey") ?? Self.newKey()
        phones = defaults.stringArray(forKey: "hostControlPhones") ?? []
        defaults.set(key, forKey: "hostControlKey")
    }

    /// Revokes every phone by replacing the key.
    public func forget() {
        key = Self.newKey()
        phones = []
        save()
    }

    /// Gives `session` the key and phone count, and handles phones checking in and the web page's
    /// "forget other hosts" (the asking phone gets the new key). `onPhone` runs for each check-in.
    public func attach(to session: PartySession, onPhone: (@MainActor (String) -> Void)? = nil) {
        session.hostKey = key
        session.hostPhoneCount = phones.count
        session.onHostPhone = { [weak self, weak session] clientID in
            guard let self else { return }
            if !self.phones.contains(clientID) {
                self.phones.append(clientID)
                self.save()
                session?.hostPhoneCount = self.phones.count
            }
            onPhone?(clientID)
        }
        session.onForgetHostPhones = { [weak self, weak session] in
            guard let self else { return nil }
            self.forget()
            session?.hostKey = self.key
            session?.hostPhoneCount = 0
            return self.key
        }
    }

    private func save() {
        defaults.set(key, forKey: "hostControlKey")
        defaults.set(phones, forKey: "hostControlPhones")
    }

    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
