@testable import CanopyMusicCore
@testable import CanopyMusicServer
import CryptoKit
import Foundation
import Network
import Testing

/// Zones announce which Spotify account they play from (as a fingerprint), so a device can see
/// another zone already using its account before it starts one.
struct SpotifyAccountTests {
    func roundTrip(_ txt: [String: String]) throws -> ZoneListing {
        let record = NWTXTRecord(ZoneAdvertiser.txtRecord(txt))
        return try #require(ZoneBrowser.listing(instance: "Den", txt: record.dictionary))
    }

    @Test func fingerprintIsStableAndHidesTheID() {
        let id = "naren.spotify.user"
        let fingerprint = SpotifyAccount.fingerprint(userID: id)
        #expect(fingerprint == SpotifyAccount.fingerprint(userID: id))
        #expect(fingerprint.count == 12)
        #expect(fingerprint.allSatisfy { $0.isHexDigit })
        #expect(!fingerprint.contains(id))
        #expect(fingerprint != SpotifyAccount.fingerprint(userID: "someone.else"))
        // Peers on other builds must agree: the start of SHA-256 of the prefixed id, in hex.
        let digest = SHA256.hash(data: Data("canopymusic-spotify:\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(fingerprint == String(digest.prefix(12)))
    }

    @Test func txtRecordCarriesTheAccount() throws {
        let fingerprint = SpotifyAccount.fingerprint(userID: "naren.spotify.user")
        let spotify = try roundTrip(["name": "Den", "kind": "ipad", "addr": "10.0.1.5", "hub": "ipad-1",
                                     ZoneService.spotifyAccountKey: fingerprint])
        #expect(spotify.spotifyAccount == fingerprint)
        #expect(spotify.hubID == "ipad-1")
        // Apple Music zones, TVs and older hubs leave it out.
        let appleMusic = try roundTrip(["name": "Den", "kind": "ipad", "addr": "10.0.1.5", "hub": "ipad-1"])
        #expect(appleMusic.spotifyAccount == nil)
        let blank = try roundTrip(["name": "Den", "kind": "ipad", "addr": "10.0.1.5", ZoneService.spotifyAccountKey: ""])
        #expect(blank.spotifyAccount == nil)
    }

    @Test func findsAnotherZoneOnTheAccount() {
        let mine = SpotifyAccount.fingerprint(userID: "me")
        let theirs = SpotifyAccount.fingerprint(userID: "them")
        let own = ZoneListing(id: "Study", name: "Study", kind: .ipad, address: "10.0.1.2", hubID: "self", spotifyAccount: mine)
        let appleMusic = ZoneListing(id: "Kitchen", name: "Kitchen", kind: .ipad, address: "10.0.1.3", hubID: "ipad-2")
        let tv = ZoneListing(id: "Living Room", name: "Living Room", kind: .tv, address: "10.0.1.4", hubID: "tv-1")
        let otherAccount = ZoneListing(id: "Patio", name: "Patio", kind: .ipad, address: "10.0.1.5", hubID: "ipad-3", spotifyAccount: theirs)
        let sameAccount = ZoneListing(id: "Den", name: "Den", kind: .ipad, device: "MacBookAir", address: "10.0.1.6", hubID: "mac-1", spotifyAccount: mine)

        // Finds the zone on this account.
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [own, appleMusic, tv, otherAccount, sameAccount], ownHubID: "self") == sameAccount)
        // Never this device's own zone.
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [own], ownHubID: "self") == nil)
        // Apple Music zones, TVs and other accounts don't count.
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [appleMusic, tv, otherAccount], ownHubID: "self") == nil)
        // An account not known yet matches nothing, not even zones without one.
        #expect(ZoneListing.usingSpotifyAccount(nil, in: [appleMusic, tv, sameAccount], ownHubID: "self") == nil)
        #expect(ZoneListing.usingSpotifyAccount("", in: [appleMusic, tv, sameAccount], ownHubID: "self") == nil)
    }
}
