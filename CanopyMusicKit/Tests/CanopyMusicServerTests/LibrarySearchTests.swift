@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import Testing

/// The hub's own library songs show in hosts' searches only (`PartyServer.searchShowsLibrary`).
@MainActor
@Suite(.serialized)
struct LibrarySearchTests {
    func search(_ port: UInt16, _ query: String) async throws -> [QueueTrack] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/search?\(query)")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder.api.decode([QueueTrack].self, from: data)
    }

    @Test func theSwitch() {
        // One switch opens it to guests; it's closed.
        #expect(!PartyServer.guestsSearchTheLibrary)
        #expect(PartyServer.searchShowsLibrary(isHost: true))
        #expect(!PartyServer.searchShowsLibrary(isHost: false))
    }

    @Test func hostsFindTheLibraryGuestsDont() async throws {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.hostKey = "secret"
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18866]))
        defer { task.cancel(); Task { await server.stop() } }

        // A guest: the catalog only, and no library copies.
        let guest = try await search(18866, "q=harbour")
        #expect(guest.isEmpty)
        let guestDreams = try await search(18866, "q=dreams")
        #expect(guestDreams.map(\.id) == ["demo-1"])
        #expect(guestDreams.allSatisfy { $0.libraryID == nil })
        // A wrong key is a guest.
        #expect(try await search(18866, "q=harbour&key=nope").isEmpty)
        // A display (no key) searches as a guest does.
        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18866")!, clientID: "kitchen", name: "Kitchen iPad", kind: .ipad)
        #expect(try await connection.search("harbour").isEmpty)

        // A host: the upload only in the library, with relayed art and its library id...
        let host = try await search(18866, "q=harbour&key=secret")
        let upload = try #require(host.first)
        #expect(host.count == 1)
        #expect(upload.isLibraryOnly)
        #expect(upload.id == "i.DemoUpload1")
        #expect(upload.thumbnailURL?.relativeString == "/api/artwork/i.DemoUpload1?size=160")
        // ...and the library's copy of a catalog song in place of the catalog's, once.
        let dreams = try await search(18866, "q=dreams&key=secret")
        #expect(dreams.map(\.id) == ["demo-1"])
        #expect(dreams.first?.libraryID == "i.DemoDreams1")
        #expect(dreams.first?.title == "Dreams (2004 Remaster)")

        // A host adds it as the page does (the whole track), and it plays as it was found.
        _ = hub.add(upload, by: Requester(name: "Host", clientID: "host", origin: .phone))
        #expect(hub.state.upNext.contains { $0.track.libraryID == "i.DemoUpload1" })
        // Its art is there.
        let (art, response) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:18866/api/artwork/i.DemoUpload1?size=160")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!art.isEmpty)
    }
}
