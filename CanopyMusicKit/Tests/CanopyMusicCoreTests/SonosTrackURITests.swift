import Foundation
import Testing
@testable import CanopyMusicCore

struct SonosTrackURITests {
    let spotify = SonosTrackReference(service: .spotify, accountSerial: 4)
    let appleMusic = SonosTrackReference(service: .appleMusic, accountSerial: 3)

    /// Exactly what the Sonos app put in a real S2 queue for this track.
    @Test func spotifyMatchesARealQueueEntry() throws {
        let uri = try spotify.uri(for: "spotify:track:3eXYltBvZSCOs6fM1La6ho")
        #expect(uri == "x-sonos-spotify:spotify%3atrack%3a3eXYltBvZSCOs6fM1La6ho?sid=12&flags=8232&sn=4")
        #expect(try spotify.itemID(for: "spotify:track:3eXYltBvZSCOs6fM1La6ho") == "00032020spotify%3atrack%3a3eXYltBvZSCOs6fM1La6ho")
        // A bare id works too.
        #expect(try spotify.uri(for: "3eXYltBvZSCOs6fM1La6ho") == uri)
        // And it reads back as the id Canopy Music uses.
        #expect(SonosURI.canopyTrackID(of: uri) == "spotify:track:3eXYltBvZSCOs6fM1La6ho")
        #expect(SonosURI.serviceAndAccount(of: uri)?.serviceID == 12)
        #expect(SonosURI.serviceAndAccount(of: uri)?.serial == 4)
    }

    /// Community-documented, not yet seen on a real household.
    @Test func appleMusicFormat() throws {
        let uri = try appleMusic.uri(for: "1440857781")
        #expect(uri == "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8224&sn=3")
        #expect(try appleMusic.itemID(for: "1440857781") == "10032020song%3a1440857781")
        #expect(SonosURI.canopyTrackID(of: uri) == "1440857781")
        #expect(SonosURI.serviceAndAccount(of: uri)?.serviceID == 204)
    }

    /// What a real S2 household's queue held for an Apple Music song Canopy Music played: Sonos's
    /// own streaming form. It must still read as the same song.
    @Test func appleMusicAsSonosKeepsIt() {
        let uri = "x-sonosapi-hls-static:song%3a1466310464?sid=204&flags=8232&sn=3"
        #expect(SonosURI.canopyTrackID(of: uri) == "1466310464")
        #expect(SonosURI.serviceAndAccount(of: uri)?.serviceID == 204)
        #expect(SonosURI.canopyTrackID(of: "x-sonosapi-hls:song%3a1466310464?sid=204&flags=8232&sn=3") == "1466310464")
    }

    static let upload = QueueTrack.libraryOnly(
        libraryID: "i.bVl4FRZ1zY", title: "Chip the Glasses, Crack the Plates! (Film Version)",
        artist: "Glenn Yarbrough", album: "The Hobbit (Original Motion Picture Soundtrack)", duration: 20.3
    )

    /// A library-only song: exactly what the Sonos app put in a real queue (and what played from
    /// the debug Library test), and the DIDL that played with it.
    @Test func appleMusicLibraryTrack() throws {
        let uri = try appleMusic.uri(for: Self.upload)
        #expect(uri == "x-sonos-http:librarytrack%3ai.bVl4FRZ1zY.unknown?sid=204&flags=0&sn=3")
        #expect(SonosURI.canopyTrackID(of: uri) == "i.bVl4FRZ1zY")
        #expect(SonosURI.serviceAndAccount(of: uri)?.serviceID == 204)
        #expect(SonosURI.serviceAndAccount(of: uri)?.serial == 3)
        let metadata = try appleMusic.metadata(for: Self.upload)
        #expect(metadata.contains("<res protocolInfo=\"sonos.com-http:*:application/octet-stream:*\" duration=\"0:00:20\">x-sonos-http:librarytrack%3ai.bVl4FRZ1zY.unknown?sid=204&amp;flags=0&amp;sn=3</res>"))
        let item = try #require(SonosParse.didlItems(metadata).first)
        #expect(item.id == "10032020librarytrack%3ai.bVl4FRZ1zY")
        #expect(item.title == "Chip the Glasses, Crack the Plates! (Film Version)")
        #expect(item.desc == "SA_RINCON52231_X_#Svc52231-0-Token")
        // A catalog song still goes by its catalog id, and so does a library copy of one.
        let catalog = QueueTrack(id: "1440857781", title: "t", artist: "a")
        #expect(try appleMusic.uri(for: catalog) == "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8224&sn=3")
        let copy = catalog.libraryCopy(libraryID: "i.Matched1", title: nil, artist: nil, album: nil)
        #expect(try appleMusic.uri(for: copy) == "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8224&sn=3")
        #expect(try SonosParse.didlItems(appleMusic.metadata(for: copy)).first?.id == "10032020song%3a1440857781")
    }

    /// What Sonos reports once it plays the library song (`GetPositionInfo`, its queue): its own
    /// `.mp4` form, flags 8232, as in raw XML too. It must still read as the same song.
    @Test func appleMusicLibraryTrackAsSonosKeepsIt() {
        #expect(SonosURI.canopyTrackID(of: "x-sonos-http:librarytrack%3ai.bVl4FRZ1zY.mp4?sid=204&flags=8232&sn=3") == "i.bVl4FRZ1zY")
        #expect(SonosURI.canopyTrackID(of: "x-sonos-http:librarytrack%3ai.bVl4FRZ1zY.mp4?sid=204&amp;flags=8232&amp;sn=3") == "i.bVl4FRZ1zY")
        #expect(SonosURI.canopyTrackID(of: "x-sonos-http:librarytrack%3ai.bVl4FRZ1zY.unknown") == "i.bVl4FRZ1zY")
        #expect(SonosURI.canopyTrackID(of: "x-sonos-http:librarytrack%3ai.bVl4FRZ1zY") == "i.bVl4FRZ1zY")
        #expect(SonosURI.serviceAndAccount(of: "x-sonos-http:librarytrack%3ai.bVl4FRZ1zY.mp4?sid=204&flags=8232&sn=3")?.serial == 3)
        // Not a library id: not ours.
        #expect(SonosURI.canopyTrackID(of: "x-sonos-http:librarytrack%3a12345.mp4?sid=204") == nil)
        #expect(SonosURI.canopyTrackID(of: "x-sonos-http:librarytrack%3a.mp4?sid=204") == nil)
    }

    @Test func libraryTracksSonosCantPlay() {
        // Not a library id, or a library song on a Spotify zone.
        var odd = Self.upload
        odd.libraryID = "i.abc&sn=9"
        odd.id = "i.abc&sn=9"
        #expect(throws: SonosTrackReference.Failure.self) { try appleMusic.uri(for: odd) }
        #expect(throws: SonosTrackReference.Failure.self) { try appleMusic.metadata(for: odd) }
        #expect(throws: SonosTrackReference.Failure.self) { try spotify.uri(for: Self.upload) }
        #expect(throws: SonosTrackReference.Failure.self) { try spotify.metadata(for: Self.upload) }
    }

    @Test func tracksSonosCantPlay() {
        #expect(throws: SonosTrackReference.Failure.self) { try appleMusic.uri(for: "i.ABC123") }
        #expect(throws: SonosTrackReference.Failure.self) { try appleMusic.uri(for: "") }
        #expect(throws: SonosTrackReference.Failure.self) { try spotify.uri(for: "spotify:episode:abc") }
        #expect(throws: SonosTrackReference.Failure.self) { try spotify.uri(for: "spotify:local:a:b:c:1") }
    }

    @Test func tokens() {
        #expect(spotify.resolvedToken == "SA_RINCON3079_X_#Svc3079-0-Token")
        #expect(appleMusic.resolvedToken == "SA_RINCON52231_X_#Svc52231-0-Token")
        let own = SonosTrackReference(service: .spotify, accountSerial: 4, token: "SA_RINCON3079_X_#Svc3079-1a2b-Token")
        #expect(own.resolvedToken == "SA_RINCON3079_X_#Svc3079-1a2b-Token")
    }

    @Test func metadataIsEscapedDIDL() throws {
        let track = QueueTrack(id: "spotify:track:abc", title: "Rock & Roll <Live> \"Encore\"", artist: "AC/DC's", album: "If You Want Blood")
        let metadata = try spotify.metadata(for: track)
        #expect(metadata.contains("<dc:title>Rock &amp; Roll &lt;Live&gt; &quot;Encore&quot;</dc:title>"))
        #expect(metadata.contains("<dc:creator>AC/DC&apos;s</dc:creator>"))
        #expect(metadata.contains("SA_RINCON3079_X_#Svc3079-0-Token"))
        // Well-formed, and it reads back as an item.
        let item = try #require(SonosParse.didlItems(metadata).first)
        #expect(item.id == "00032020spotify%3atrack%3aabc")
        #expect(item.title == "Rock & Roll <Live> \"Encore\"")
        #expect(item.creator == "AC/DC's")
        #expect(item.upnpClass == "object.item.audioItem.musicTrack")
        #expect(item.desc == "SA_RINCON3079_X_#Svc3079-0-Token")
    }

    /// The metadata goes into the SOAP envelope as text: escaped once more, and back intact.
    @Test func metadataSurvivesTheEnvelope() throws {
        let track = QueueTrack(id: "1440857781", title: "Ça & ça", artist: "Él")
        let metadata = try appleMusic.metadata(for: track)
        let request = SonosRequest(host: "h", service: .avTransport, action: "AddURIToQueue",
                                   arguments: [.init("InstanceID", "0"), .init("EnqueuedURIMetaData", metadata)])
        #expect(request.envelope.contains("&lt;dc:title&gt;Ça &amp;amp; ça&lt;/dc:title&gt;"))
        let root = try #require(SonosXMLElement.parse(request.envelope))
        #expect(root.first("EnqueuedURIMetaData")?.text == metadata)
        #expect(root.first("AddURIToQueue")?.name == "u:AddURIToQueue")
    }

    @Test func otherURIsAreNotTracks() {
        #expect(SonosURI.canopyTrackID(of: "x-sonos-vli:RINCON_347E5C81C63501400:2,spotify:f1e37b") == nil)
        #expect(SonosURI.canopyTrackID(of: "x-rincon-stream:RINCON_X") == nil)
        #expect(SonosURI.canopyTrackID(of: "x-sonos-htastream:RINCON_X:spdif") == nil)
        #expect(SonosURI.serviceAndAccount(of: "x-rincon-queue:RINCON_X#0") == nil)
        #expect(SonosURI.serviceAndAccount(of: "x-sonosapi-radio:abc?sid=303&flags=8296")?.serial == nil)
        #expect(SonosURI.serviceAndAccount(of: "x-sonos-spotify:x?sid=12&amp;flags=8232&amp;sn=7")?.serial == 7)
        #expect(SonosURI.queue(of: "RINCON_A") == "x-rincon-queue:RINCON_A#0")
        #expect(SonosURI.joinGroup(of: "RINCON_A") == "x-rincon:RINCON_A")
    }

    @Test func readOnlyActions() {
        #expect(SonosRequest(host: "h", service: .avTransport, action: "GetPositionInfo").isReadOnly)
        #expect(!SonosRequest(host: "h", service: .avTransport, action: "Play").isReadOnly)
        #expect(!SonosRequest(host: "h", service: .avTransport, action: "AddURIToQueue").isReadOnly)
    }
}
