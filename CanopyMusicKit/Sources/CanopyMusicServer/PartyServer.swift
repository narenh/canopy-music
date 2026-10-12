import CanopyMusicCore
import CoreImage
import CoreImage.CIFilterBuiltins
import FlyingFox
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
                    // Don't wait: stopping a server that never got its port can hang.
                    Task { await server.stop() }
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
        // icon.png is square (iOS rounds home screen icons itself); favicon.png is already rounded.
        await server.appendRoute("GET /icon.png", to: StaticFile("icon.png", type: "image/png"))
        await server.appendRoute("GET /favicon.png", to: StaticFile("favicon.png", type: "image/png"))
        await server.appendRoute("GET /favicon.ico", to: StaticFile("favicon.png", type: "image/png"))
        // The page's redirect check: an image only if this is the hub at `lan`, so a friendly name
        // that reaches a different zone (both answer as Canopy Music) doesn't count.
        await server.appendRoute("GET /api/same.png") { request in
            guard let lan = request.query["lan"], await session.lanAddress == lan else { return HTTPResponse(statusCode: .notFound) }
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "image/png"], body: Self.pixelPNG)
        }

        await server.appendRoute("GET /api/state") { _ in
            try .json(await session.snapshot())
        }

        await server.appendRoute("GET /api/search") { request in
            let term = request.query["q"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !term.isEmpty else { return try .json([QueueTrack]()) }
            do {
                return try .json(try await session.catalog.searchSongs(term))
            } catch {
                return .serviceFailed(error)
            }
        }

        await server.appendRoute("POST /api/add") { request in
            let body = try JSONDecoder.api.decode(AddBody.self, from: await request.bodyData)
            // Displays (Canopy devices showing this zone) add as "iPad" requests with their own name
            // and pick the item ID, so their optimistic copy matches.
            let requester = Requester(name: body.name?.cleanedName, clientID: body.clientId, origin: body.origin == "ipad" ? .ipad : .phone)
            let result = if let itemId = body.itemId {
                await session.add(body.track, by: requester, id: itemId)
            } else {
                await session.add(body.track, by: requester)
            }
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

        // Displays: other Canopy devices showing this zone.
        await server.appendRoute("POST /api/display/hello") { request in
            let body = try JSONDecoder.api.decode(DisplayHello.self, from: await request.bodyData)
            await session.noteDisplay(ZoneDisplay(id: body.clientId, name: body.name, kind: body.kind))
            return HTTPResponse(statusCode: .ok)
        }

        await server.appendRoute("POST /api/display/playback") { request in
            let body = try JSONDecoder.api.decode(PlaybackBody.self, from: await request.bodyData)
            guard await session.displaysCanControl else { return HTTPResponse(statusCode: .forbidden) }
            return await Self.playback(body, session: session)
        }

        // Hosts on the web page (with the Host Control key).
        await server.appendRoute("GET /api/host/playlists") { request in
            guard await session.isHost(key: request.query["key"]) else { return HTTPResponse(statusCode: .forbidden) }
            do {
                return try .json(try await session.catalog.libraryPlaylists())
            } catch {
                return .serviceFailed(error)
            }
        }

        await server.appendRoute("POST /api/host/playlist") { request in
            let body = try JSONDecoder.api.decode(PlaylistBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            do {
                try await session.load(playlist: body.playlist)
                if body.play == true { try await session.play() }
            } catch {
                return .serviceFailed(error)
            }
            return HTTPResponse(statusCode: .ok)
        }

        await server.appendRoute("POST /api/host/settings") { request in
            let body = try JSONDecoder.api.decode(SettingsBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            await session.applyHostSettings(
                zoneName: body.zoneName?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40).description,
                phonesCanReorder: body.phonesCanReorder,
                displaysCanControl: body.displaysCanControl
            )
            return HTTPResponse(statusCode: .ok)
        }

        await server.appendRoute("POST /api/host/stop") { request in
            let body = try JSONDecoder.api.decode(HostBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            await session.requestStop()
            return HTTPResponse(statusCode: .ok)
        }

        // "Add another host": the hub renders the QR code, so the page needs no QR library.
        await server.appendRoute("GET /api/host/invite.png") { request in
            let key = request.query["key"]
            guard await session.isHost(key: key), let key else { return HTTPResponse(statusCode: .forbidden) }
            let address = await session.lanAddress ?? request.headers[.host] ?? ""
            guard let png = Self.qrPNG("http://\(address)/?host=\(key)") else { return HTTPResponse(statusCode: .internalServerError) }
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "image/png", .cacheControl: "no-store"], body: png)
        }

        // Host control: a phone that scanned the iPad's Host Control QR code.
        await server.appendRoute("POST /api/host/check") { request in
            let body = try JSONDecoder.api.decode(HostBody.self, from: await request.bodyData)
            return HTTPResponse(statusCode: await session.isHost(key: body.key, clientID: body.clientId) ? .ok : .forbidden)
        }

        await server.appendRoute("POST /api/host/playback") { request in
            let body = try JSONDecoder.api.decode(HostBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            return await Self.playback(PlaybackBody(action: body.action ?? "", time: body.time), session: session)
        }

        await server.appendRoute("GET /ws", to: .webSocket(SnapshotSocket(session: session)))
    }
}

// MARK: - API bodies

struct AddBody: Decodable {
    var track: QueueTrack
    var name: String?
    var clientId: String
    var itemId: UUID?
    var origin: String?
}

struct DisplayHello: Decodable {
    var clientId: String
    var name: String
    var kind: HubKind
}

struct PlaybackBody: Decodable {
    var action: String
    var time: TimeInterval?
}

struct PlaylistBody: Decodable {
    var key: String
    var playlist: PlaylistSummary
    var play: Bool?
}

struct SettingsBody: Decodable {
    var key: String
    var zoneName: String?
    var phonesCanReorder: Bool?
    var displaysCanControl: Bool?
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
    var time: TimeInterval?
}

extension PartyServer {
    @MainActor
    static func playback(_ body: PlaybackBody, session: PartySession) async -> HTTPResponse {
        switch body.action {
        case "play":
            do { try await session.play() } catch { return .serviceFailed(error) }
        case "pause": session.pause()
        case "next": await session.skip()
        case "previous": await session.previous()
        case "seek":
            guard let time = body.time else { return HTTPResponse(statusCode: .badRequest) }
            session.seek(to: time)
        default: return HTTPResponse(statusCode: .badRequest)
        }
        return HTTPResponse(statusCode: .ok)
    }

    /// A QR code as a crisp PNG (each module scaled up without smoothing).
    /// A 1×1 transparent PNG.
    static let pixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    static func qrPNG(_ payload: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
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

extension HTTPResponse {
    /// The music service failed. Debug builds say why in the body, since the hub's own console is
    /// hard to reach on an Apple TV.
    static func serviceFailed(_ error: Error) -> HTTPResponse {
        #if DEBUG
        HTTPResponse(statusCode: .badGateway, body: Data(String(reflecting: error).utf8))
        #else
        HTTPResponse(statusCode: .badGateway)
        #endif
    }
}
