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
