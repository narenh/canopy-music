import CryptoKit
import Foundation

/// Which Spotify account a hub plays from, as its zone announces it. Spotify plays one stream per
/// account, so two zones on one account fight over playback; the announcement lets a device see
/// that before it starts using the account. Only a short fingerprint goes on the network, never
/// the account's id or name.
public enum SpotifyAccount {
    /// The first 12 hex characters of SHA-256 of `canopymusic-spotify:` + the Spotify user id.
    public static func fingerprint(userID: String) -> String {
        let digest = SHA256.hash(data: Data("canopymusic-spotify:\(userID)".utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
