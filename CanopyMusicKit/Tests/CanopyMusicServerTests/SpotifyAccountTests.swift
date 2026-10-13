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

    /// Apple TV hubs play Spotify too, and announce the account the same way.
    @Test func aTVZoneOnTheAccountCounts() throws {
        let mine = SpotifyAccount.fingerprint(userID: "me")
        let tv = try roundTrip(["name": "Bedroom TV", "kind": "tv", "addr": "10.0.1.7", "hub": "tv-1", ZoneService.spotifyAccountKey: mine])
        #expect(tv.kind == .tv && tv.spotifyAccount == mine)
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [tv], ownHubID: "ipad-1") == [tv])
        // …and a TV checks iPad zones (and other TVs) before starting its own.
        let ipad = try roundTrip(["name": "Den", "kind": "ipad", "addr": "10.0.1.5", "hub": "ipad-1", ZoneService.spotifyAccountKey: mine])
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [ipad, tv], ownHubID: "tv-1") == [ipad])
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
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [own, appleMusic, tv, otherAccount, sameAccount], ownHubID: "self") == [sameAccount])
        // Never this device's own zone.
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [own], ownHubID: "self").isEmpty)
        // Apple Music zones, TVs and other accounts don't count.
        #expect(ZoneListing.usingSpotifyAccount(mine, in: [appleMusic, tv, otherAccount], ownHubID: "self").isEmpty)
        // An account not known yet matches nothing, not even zones without one.
        #expect(ZoneListing.usingSpotifyAccount(nil, in: [appleMusic, tv, sameAccount], ownHubID: "self").isEmpty)
        #expect(ZoneListing.usingSpotifyAccount("", in: [appleMusic, tv, sameAccount], ownHubID: "self").isEmpty)
    }
}

/// A zone's announcement can outlive its hub (quit from Xcode, or asleep, with no Bonjour
/// goodbye), so a zone on the account blocks only if it answers `GET /api/zone`, within the
/// timeout, as the same hub on the same account.
@MainActor
@Suite(.serialized) struct ZoneProbeTests {
    let mine = SpotifyAccount.fingerprint(userID: "me")

    /// A hub running its server on `port`: hub ID `hubID`, announcing `account`.
    struct Hub {
        let session: PartySession
        let server: PartyServer
        let task: Task<Void, Error>

        func stop() async {
            task.cancel()
            await server.stop()
        }
    }

    func startHub(port: UInt16, hubID: String, account: String?) async throws -> Hub {
        let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        session.configureHub(kind: .ipad, device: "MacBookAir", id: hubID, zoneName: "Den", serviceName: "Spotify")
        session.announcedSpotifyAccount = account
        let (server, task) = try #require(await PartyServer.start(session: session, ports: [port]))
        return Hub(session: session, server: server, task: task)
    }

    /// The zone as the announcement lists it: the Mac `mac-1`, on this account.
    func listing(port: UInt16, name: String = "Den", hubID: String = "mac-1") -> ZoneListing {
        ZoneListing(id: name, name: name, kind: .ipad, device: "MacBookAir", address: "127.0.0.1:\(port)",
                    hubID: hubID, spotifyAccount: mine)
    }

    @Test func aZoneThatAnswersIsAConflict() async throws {
        let hub = try await startHub(port: 18821, hubID: "mac-1", account: mine)
        defer { Task { await hub.stop() } }
        let den = listing(port: 18821)
        // What it answers: only what its TXT record already says.
        let (data, _) = try await URLSession.shared.data(from: try #require(URL(string: "http://127.0.0.1:18821/api/zone")))
        #expect(try JSONDecoder().decode(ZoneCheck.self, from: data) == ZoneCheck(hub: "mac-1", spotify: mine))
        let probe = ZoneProbe()
        #expect(await probe.ask(den, fingerprint: mine) == .there)
        #expect(await probe.zoneUsingSpotifyAccount(mine, in: [den], ownHubID: "ipad-1") == den)
    }

    @Test func aZoneThatRefusesIsGone() async {
        // Nothing listens there: the hub quit and its announcement lingers.
        let den = listing(port: 18829)
        let probe = ZoneProbe()
        #expect(await probe.ask(den, fingerprint: mine) == .silent)
        #expect(await probe.zoneUsingSpotifyAccount(mine, in: [den], ownHubID: "ipad-1") == nil)
    }

    @Test func aZoneThatTimesOutIsGone() async {
        // An address that takes the request but never answers (a sleeping Mac's, say).
        let probe = ZoneProbe(timeout: .milliseconds(200)) { _ in
            try await Task.sleep(for: .seconds(30))
            return (Data(), 200)
        }
        let start = ContinuousClock.now
        #expect(await probe.zoneUsingSpotifyAccount(mine, in: [listing(port: 18829)], ownHubID: "ipad-1") == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func anotherHubAtTheAddressIsGone() async throws {
        // The address went to another device's zone since.
        let hub = try await startHub(port: 18822, hubID: "tv-9", account: mine)
        defer { Task { await hub.stop() } }
        let den = listing(port: 18822)
        let probe = ZoneProbe()
        #expect(await probe.ask(den, fingerprint: mine) == .otherHub)
        #expect(await probe.zoneUsingSpotifyAccount(mine, in: [den], ownHubID: "ipad-1") == nil)
    }

    @Test func aHubOffTheAccountIsGone() async throws {
        // The same hub, but not on this account any more (or not on Spotify at all).
        let hub = try await startHub(port: 18823, hubID: "mac-1", account: nil)
        defer { Task { await hub.stop() } }
        let den = listing(port: 18823)
        let probe = ZoneProbe()
        #expect(await probe.ask(den, fingerprint: mine) == .otherAccount)
        #expect(await probe.zoneUsingSpotifyAccount(mine, in: [den], ownHubID: "ipad-1") == nil)
        hub.session.announcedSpotifyAccount = SpotifyAccount.fingerprint(userID: "them")
        #expect(await probe.ask(den, fingerprint: mine) == .otherAccount)
    }

    @Test func severalMatchTheFirstThatAnswersWins() async throws {
        let hub = try await startHub(port: 18824, hubID: "tv-1", account: mine)
        defer { Task { await hub.stop() } }
        let stale = listing(port: 18829, name: "Study")
        let living = listing(port: 18824, name: "Living Room", hubID: "tv-1")
        let probe = ZoneProbe()
        #expect(await probe.zoneUsingSpotifyAccount(mine, in: [stale, living], ownHubID: "ipad-1") == living)
        // Its own zone is never asked about.
        #expect(await probe.zoneUsingSpotifyAccount(mine, in: [stale, living], ownHubID: "tv-1") == nil)
    }

    @Test func aHubFromBeforeTheCheckCountsByItsSnapshot() async throws {
        // Older hubs have no `/api/zone`: one that answers its snapshot as the same hub is there.
        let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        session.configureHub(kind: .ipad, id: "mac-1", zoneName: "Den", serviceName: "Spotify")
        let state = try JSONEncoder.api.encode(session.snapshot())
        let probe = ZoneProbe { url in url.path == "/api/state" ? (state, 200) : (Data(), 404) }
        #expect(await probe.ask(listing(port: 18829), fingerprint: mine) == .there)
        #expect(await probe.ask(listing(port: 18829, hubID: "tv-9"), fingerprint: mine) == .otherHub)
    }
}
