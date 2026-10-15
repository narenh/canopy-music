import Foundation
import Testing
@testable import CanopyMusicCore

/// Songs only in the hub account's iCloud Music Library (`QueueTrack.libraryID`): the model, its
/// JSON (old payloads too), and the relayed artwork's paths.
@Suite struct LibraryTrackTests {
    let upload = QueueTrack.libraryOnly(
        libraryID: "i.bVl4FRZ1zY", title: "Chip the Glasses, Crack the Plates! (Film Version)",
        artist: "Glenn Yarbrough", album: "The Hobbit (Original Motion Picture Soundtrack)", duration: 20.3
    )

    @Test func libraryOnlyTrack() {
        #expect(upload.id == "i.bVl4FRZ1zY")
        #expect(upload.libraryID == "i.bVl4FRZ1zY")
        #expect(upload.artworkURL?.relativeString == "/api/artwork/i.bVl4FRZ1zY?size=1200")
        #expect(upload.thumbnailURL?.relativeString == "/api/artwork/i.bVl4FRZ1zY?size=160")
        #expect(upload.artworkURL?.scheme == nil)
        #expect(upload.albumID == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(upload)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["libraryID"] as? String == "i.bVl4FRZ1zY")
        // The page uses the path as it is: relative, so it loads from the hub that served it.
        #expect(object["artworkURL"] as? String == "/api/artwork/i.bVl4FRZ1zY?size=1200")
        #expect(try JSONDecoder().decode(QueueTrack.self, from: data) == upload)
    }

    /// Catalog songs don't carry the key at all, so older peers see what they always did.
    @Test func catalogSongsLeaveItOut() throws {
        let catalog = QueueTrack(id: "1440857781", title: "Song", artist: "Artist")
        let json = String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self)
        #expect(!json.contains("libraryID"))
    }

    /// A saved queue or an older client's track from before `libraryID`.
    @Test func oldPayloadsStillDecode() throws {
        let old = #"{"id":"1440857781","title":"Song","artist":"Artist","album":"Album","isExplicit":false,"artworkURL":"https://is1-ssl.mzstatic.com/image/a.jpg"}"#
        let track = try JSONDecoder().decode(QueueTrack.self, from: Data(old.utf8))
        #expect(track.libraryID == nil)
        #expect(track.artworkURL?.absoluteString == "https://is1-ssl.mzstatic.com/image/a.jpg")
    }

    /// The hub's saved queue keeps library songs as they were.
    @Test func savedQueueKeepsThem() throws {
        var state = QueueState()
        state.load(playlist: [track("a"), upload, track("b")], name: "Mixed")
        state.advance()
        _ = state.addRequest(upload, by: guest)
        let restored = try JSONDecoder().decode(QueueState.self, from: try JSONEncoder().encode(state))
        #expect(restored == state)
        #expect(restored.upNext.contains { $0.track.libraryID == "i.bVl4FRZ1zY" })
    }

    /// The same library song is the same song, wherever it was found.
    @Test func sameLibraryIDIsAlreadyQueued() {
        var state = QueueState()
        state.load(playlist: [track("a"), track("b")], name: "Base")
        state.advance()
        guard case .added = state.addRequest(upload, by: guest) else { Issue.record("not added"); return }
        var again = upload
        again.title = "Chip the Glasses (as the web page sent it)"
        guard case .alreadyQueued = state.addRequest(again, by: Requester(name: "Kim", clientID: "phone-2", origin: .phone)) else {
            Issue.record("queued twice")
            return
        }
    }

    @Test func libraryIDs() {
        #expect(LibraryArtwork.isLibraryID("i.bVl4FRZ1zY"))
        #expect(!LibraryArtwork.isLibraryID("1440857781"))
        #expect(!LibraryArtwork.isLibraryID("i."))
        #expect(!LibraryArtwork.isLibraryID("i.abc/../x"))
        #expect(!LibraryArtwork.isLibraryID("i.abc?size=1"))
        #expect(!LibraryArtwork.isLibraryID("spotify:track:abc"))
        #expect(!LibraryArtwork.isLibraryID("i." + String(repeating: "a", count: 80)))
    }

    /// A display loads relayed art from its zone's hub, and catalog art from where it always did.
    @Test func displaysResolveAgainstTheirHub() {
        let hub = URL(string: "http://10.0.1.5:8080")!
        let catalog = QueueTrack(id: "1", title: "Song", artist: "Artist", artworkURL: URL(string: "https://is1-ssl.mzstatic.com/a.jpg"))
        let snapshot = PartySnapshot(
            version: 1, current: QueueItem(track: upload, requester: nil), upNext: [QueueItem(track: catalog, requester: nil)],
            playback: PlaybackSnapshot(isPlaying: true, position: 0, capturedAt: Date()), canReorder: true,
            history: [QueueItem(track: upload, requester: guest)]
        )
        let resolved = snapshot.resolvingArtwork(against: hub)
        #expect(resolved.current?.track.artworkURL?.absoluteString == "http://10.0.1.5:8080/api/artwork/i.bVl4FRZ1zY?size=1200")
        #expect(resolved.current?.track.thumbnailURL?.absoluteString == "http://10.0.1.5:8080/api/artwork/i.bVl4FRZ1zY?size=160")
        #expect(resolved.history?.first?.track.thumbnailURL?.host == "10.0.1.5")
        #expect(resolved.upNext.first?.track.artworkURL?.absoluteString == "https://is1-ssl.mzstatic.com/a.jpg")
        // Resolving twice changes nothing more.
        #expect(resolved.resolvingArtwork(against: URL(string: "http://elsewhere")!) == resolved)
    }
}
