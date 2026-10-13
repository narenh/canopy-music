import Foundation
import Testing
@testable import CanopyMusicCore

/// `QueueTrack.albumID` is optional in JSON: saved queues and snapshots from before it still
/// decode, and peers that don't know it can ignore it.
@Suite struct QueueTrackCodingTests {
    /// A track as builds before `albumID` encoded it.
    static let withoutAlbumID = Data(#"""
    {"id": "1440833101", "title": "Forever", "artist": "Gryffin", "album": "Forever - Single",
     "duration": 200, "artworkURL": "https://is1-ssl.mzstatic.com/a/1200x1200.jpg", "isExplicit": false}
    """#.utf8)

    static let withAlbumID = Data(#"""
    {"id": "1440833101", "title": "Forever", "artist": "Gryffin", "album": "Forever - Single",
     "isExplicit": true, "albumID": "1440833098"}
    """#.utf8)

    @Test func decodesWithoutAlbumID() throws {
        let track = try JSONDecoder().decode(QueueTrack.self, from: Self.withoutAlbumID)
        #expect(track.albumID == nil)
        #expect(track.id == "1440833101")
        #expect(track.duration == 200)
        #expect(track.artworkURL?.absoluteString == "https://is1-ssl.mzstatic.com/a/1200x1200.jpg")
    }

    @Test func decodesWithAlbumID() throws {
        let track = try JSONDecoder().decode(QueueTrack.self, from: Self.withAlbumID)
        #expect(track.albumID == "1440833098")
        #expect(track.isExplicit)
        #expect(track.duration == nil)
    }

    @Test func roundTrips() throws {
        let track = QueueTrack(id: "1", title: "T", artist: "A", album: "B", albumID: "1440833098")
        #expect(try JSONDecoder().decode(QueueTrack.self, from: JSONEncoder().encode(track)) == track)
    }

    /// No `albumID` key is written when there's none, so the JSON is as before.
    @Test func leavesOutAMissingAlbumID() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(QueueTrack(id: "1", title: "T", artist: "A"))) as? [String: Any]
        #expect(json?["albumID"] == nil)
        #expect(json?["title"] as? String == "T")
    }

    /// What an older peer does with the new JSON: a decoder that doesn't know `albumID` ignores it.
    @Test func olderDecodersIgnoreIt() throws {
        struct OldQueueTrack: Decodable {
            var id: String
            var title: String
            var artist: String
            var album: String
            var isExplicit: Bool
        }
        let old = try JSONDecoder().decode(OldQueueTrack.self, from: Self.withAlbumID)
        #expect(old.id == "1440833101")
    }
}
