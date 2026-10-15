import Foundation
import Testing
@testable import CanopyMusicCore

/// A pretend cmdlp at the URL loading level: records each request and answers from `handler`.
final class StubCmdlp: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var url: URL
        var authorization: String?
        var body: Data?
    }

    nonisolated(unsafe) static var requests: [Request] = []
    nonisolated(unsafe) static var handler: (@Sendable (Request) -> (Int, String))?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubCmdlp.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let recorded = Request(method: request.httpMethod ?? "GET", url: request.url!, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
        Self.requests.append(recorded)
        let (status, text) = Self.handler?(recorded) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The hub's cmdlp client against the API as openapi.yaml has it: the token in the
/// Authorization header only, the zone sent with each lookup, errors read from cmdlp's JSON.
@Suite(.serialized) struct CmdlpClientTests {
    static let base = URL(string: "https://cmdlp.example.com")!
    static let trackJSON = #"{"id":"M9xQFZLlR5L-VkfG3YQQLp","zone":"z1","status":"pending","title":"T","artist":"A","duration":200,"artwork":null,"service":"SoundCloud","stage":"queued","progress":null,"audioUrl":"https://cmdlp.example.com/audio/M9xQFZLlR5L-VkfG3YQQLp.m4a?sig=s","url":"x","createdAt":"2026-10-14T20:00:00Z"}"#

    func client() -> CmdlpClient {
        StubCmdlp.requests = []
        return CmdlpClient(baseURL: Self.base, token: "cmdlp_secret", urlSession: StubCmdlp.session())
    }

    @Test func resolvePostsTheLinkAndZoneWithTheToken() async throws {
        let client = client()
        StubCmdlp.handler = { _ in (200, Self.trackJSON) }
        let track = try await client.resolve("https://soundcloud.com/forss/flickermood", zone: "z1")
        #expect(track.id == "M9xQFZLlR5L-VkfG3YQQLp")
        let request = try #require(StubCmdlp.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://cmdlp.example.com/resolve")
        #expect(request.authorization == "Bearer cmdlp_secret")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String])
        #expect(body == ["url": "https://soundcloud.com/forss/flickermood", "zone": "z1"])
    }

    @Test func pollingAndZoneDelete() async throws {
        let client = client()
        StubCmdlp.handler = { request in
            request.method == "DELETE" ? (200, #"{"zone":"z1","deleted":3}"#) : (200, Self.trackJSON)
        }
        _ = try await client.track(id: "M9xQFZLlR5L-VkfG3YQQLp")
        try await client.deleteZone("z1")
        #expect(StubCmdlp.requests.map(\.method) == ["GET", "DELETE"])
        #expect(StubCmdlp.requests.map(\.url.path) == ["/tracks/M9xQFZLlR5L-VkfG3YQQLp", "/zones/z1"])
        #expect(StubCmdlp.requests.allSatisfy { $0.authorization == "Bearer cmdlp_secret" })
    }

    @Test func errorsCarryCmdlpsReasonAndSentence() async throws {
        let client = client()
        StubCmdlp.handler = { _ in (422, #"{"error":"That's a playlist, album, or set, not one track.","reason":"playlist"}"#) }
        await #expect(throws: CmdlpError(status: 422, reason: "playlist", message: "That's a playlist, album, or set, not one track.")) {
            try await client.resolve("https://youtube.com/playlist?list=x", zone: "z1")
        }
        StubCmdlp.handler = { _ in (404, #"{"error":"No such track.","reason":"not_found"}"#) }
        await #expect(throws: CmdlpError(status: 404, reason: "not_found", message: "No such track.")) {
            try await client.track(id: "AAAAAAAAAAAAAAAAAAAAAA")
        }
        StubCmdlp.handler = { _ in (502, "Bad gateway") }
        await #expect(throws: CmdlpError(status: 502)) { try await client.track(id: "AAAAAAAAAAAAAAAAAAAAAA") }
    }

    /// Test Connection: `/health` with no token, then the token on a track that can't exist
    /// (404 with a good token, 401 without).
    @Test func testConnection() async throws {
        let session = StubCmdlp.session()
        StubCmdlp.requests = []
        StubCmdlp.handler = { request in
            switch request.url.path {
            case "/health": (200, #"{"ok":true,"ytdlp":{"version":"x"}}"#)
            default: request.authorization == "Bearer good" ? (404, #"{"error":"No such track.","reason":"not_found"}"#)
                                                             : (401, #"{"error":"No bearer token.","reason":"unauthorized"}"#)
            }
        }
        #expect(await LinkConnectionCheck.run(baseURL: "https://cmdlp.example.com/", token: "good", urlSession: session)
                == "Connected. Guests can paste links into search.")
        #expect(StubCmdlp.requests.first?.authorization == nil)
        #expect(await LinkConnectionCheck.run(baseURL: "https://cmdlp.example.com", token: "bad", urlSession: session)
                == "The server is up, but it didn't accept the token.")
        #expect(await LinkConnectionCheck.run(baseURL: "https://cmdlp.example.com", token: nil, urlSession: session)
                == "The server is up. Add its API token to turn links on.")
        #expect(await LinkConnectionCheck.run(baseURL: "not a url", token: "good", urlSession: session) == "Enter the server's address first.")
        StubCmdlp.handler = { _ in (503, "") }
        #expect(await LinkConnectionCheck.run(baseURL: "https://cmdlp.example.com", token: "good", urlSession: session)
                == "Couldn't reach cmdlp.example.com.")
    }
}
