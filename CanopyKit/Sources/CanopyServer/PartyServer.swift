import CanopyCore
import FlyingFox
import Foundation

/// LAN web server that lets guests queue from their phones. Serves the web app, a small JSON API,
/// and a WebSocket that pushes a `PartySnapshot` after every change.
public final class PartyServer: Sendable {
    public let port: UInt16
    private let session: PartySession
    private let server: HTTPServer

    public init(session: PartySession, port: UInt16 = 8080) {
        self.session = session
        self.port = port
        self.server = HTTPServer(port: port, logger: .disabled)
    }

    /// Runs until cancelled.
    public func run() async throws {
        await registerRoutes()
        try await server.run()
    }

    public func stop() async {
        await server.stop()
    }

    public func waitUntilListening(timeout: TimeInterval = 2) async throws {
        try await server.waitUntilListening(timeout: timeout)
    }

    /// Starts on the first port that binds (port 80 gives guests a URL without `:port`).
    /// Returns the running server and the task driving it.
    public static func start(session: PartySession, ports: [UInt16] = [80, 8080, 8081]) async -> (PartyServer, Task<Void, Error>)? {
        for port in ports {
            // Right after a restart the previous socket can hold port 80 briefly; retry the
            // preferred port before falling back.
            let attempts = port == ports.first ? 3 : 1
            for attempt in 0..<attempts {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                let server = PartyServer(session: session, port: port)
                let task = Task { try await server.run() }
                do {
                    try await server.waitUntilListening(timeout: 1.5)
                    return (server, task)
                } catch {
                    task.cancel()
                    await server.stop()
                }
            }
        }
        return nil
    }

    /// Guest-facing URL for an address, omitting the port when it's 80.
    public func url(host: String) -> URL? {
        URL(string: port == 80 ? "http://\(host)" : "http://\(host):\(port)")
    }

    // MARK: Routes

    private func registerRoutes() async {
        let session = session

        await server.appendRoute("GET /", to: StaticFile("index.html", type: "text/html; charset=utf-8"))
        await server.appendRoute("GET /app.js", to: StaticFile("app.js", type: "text/javascript; charset=utf-8"))
        await server.appendRoute("GET /app.css", to: StaticFile("app.css", type: "text/css; charset=utf-8"))
        await server.appendRoute("GET /logo.png", to: StaticFile("logo.png", type: "image/png"))
        await server.appendRoute("GET /icon.png", to: StaticFile("icon.png", type: "image/png"))

        await server.appendRoute("GET /api/state") { _ in
            try .json(await session.snapshot())
        }

        await server.appendRoute("GET /api/search") { request in
            let term = request.query["q"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !term.isEmpty else { return try .json([QueueTrack]()) }
            do {
                return try .json(try await session.catalog.searchSongs(term))
            } catch {
                return HTTPResponse(statusCode: .badGateway)
            }
        }

        await server.appendRoute("POST /api/add") { request in
            let body = try JSONDecoder.api.decode(AddBody.self, from: await request.bodyData)
            let requester = Requester(name: body.name?.cleanedName, clientID: body.clientId, origin: .phone)
            let result = await session.add(body.track, by: requester)
            return try .json(AddReply(result))
        }

        await server.appendRoute("POST /api/move") { request in
            let body = try JSONDecoder.api.decode(MoveBody.self, from: await request.bodyData)
            let allowed = await session.phonesCanReorder
            let isHost = await session.isHost(key: body.key)
            guard allowed || isHost else { return HTTPResponse(statusCode: .forbidden) }
            let ok = await session.move(body.id, after: body.after)
            return HTTPResponse(statusCode: ok ? .ok : .conflict)
        }

        await server.appendRoute("POST /api/remove") { request in
            let body = try JSONDecoder.api.decode(RemoveBody.self, from: await request.bodyData)
            // Host control can remove anything; guests only their own requests.
            let isHost = await session.isHost(key: body.key)
            let ok = await session.remove(body.id, asClient: isHost ? nil : body.clientId)
            return HTTPResponse(statusCode: ok ? .ok : .forbidden)
        }

        // Host control: a phone that scanned the iPad's Host Control QR code.
        await server.appendRoute("POST /api/host/check") { request in
            let body = try JSONDecoder.api.decode(HostBody.self, from: await request.bodyData)
            return HTTPResponse(statusCode: await session.isHost(key: body.key, clientID: body.clientId) ? .ok : .forbidden)
        }

        await server.appendRoute("POST /api/host/playback") { request in
            let body = try JSONDecoder.api.decode(HostBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            switch body.action {
            case "play":
                do { try await session.play() } catch { return HTTPResponse(statusCode: .badGateway) }
            case "pause": await session.pause()
            case "next": await session.skip()
            case "previous": await session.previous()
            default: return HTTPResponse(statusCode: .badRequest)
            }
            return HTTPResponse(statusCode: .ok)
        }

        await server.appendRoute("GET /ws", to: .webSocket(SnapshotSocket(session: session)))
    }
}

// MARK: - API bodies

struct AddBody: Decodable {
    var track: QueueTrack
    var name: String?
    var clientId: String
}

struct AddReply: Encodable {
    var result: String
    var index: Int?
    var itemId: UUID?

    init(_ result: AddResult) {
        switch result {
        case .added(let item, let index):
            self.result = "added"; self.index = index; self.itemId = item.id
        case .alreadyQueued(let item, let index):
            self.result = "alreadyQueued"; self.index = index; self.itemId = item.id
        case .nowPlaying:
            self.result = "nowPlaying"
        }
    }
}

struct MoveBody: Decodable {
    var id: UUID
    var after: UUID?
    var key: String?
}

struct RemoveBody: Decodable {
    var id: UUID
    var clientId: String
    var key: String?
}

struct HostBody: Decodable {
    var key: String
    var clientId: String?
    var action: String?
}

// MARK: - Helpers

struct SnapshotSocket: WSMessageHandler {
    let session: PartySession

    func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        let snapshots = await session.snapshots()
        return AsyncStream { continuation in
            let pump = Task {
                for await snapshot in snapshots {
                    if let data = try? JSONEncoder.api.encode(snapshot), let text = String(data: data, encoding: .utf8) {
                        continuation.yield(.text(text))
                    }
                }
                continuation.finish()
            }
            // Drain the client side; when the phone disconnects, stop pushing.
            let drain = Task {
                for await _ in client {}
                pump.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pump.cancel()
                drain.cancel()
            }
        }
    }
}

struct StaticFile: HTTPHandler {
    let name: String
    let type: String

    init(_ name: String, type: String) {
        self.name = name
        self.type = type
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Web"),
              let data = try? Data(contentsOf: url) else {
            return HTTPResponse(statusCode: .notFound)
        }
        return HTTPResponse(statusCode: .ok, headers: [.contentType: type, .cacheControl: "no-cache"], body: data)
    }
}

extension HTTPResponse {
    static func json(_ value: some Encodable) throws -> HTTPResponse {
        HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: try JSONEncoder.api.encode(value))
    }
}

extension JSONEncoder {
    static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

extension String {
    var cleanedName: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(24))
    }
}
