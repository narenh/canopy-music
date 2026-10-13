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
        // The loading splash: the "canopy music" lockup on the Venus background.
        await server.appendRoute("GET /logo-music.png", to: StaticFile("logo-music.png", type: "image/png"))
        await server.appendRoute("GET /splash.jpg", to: StaticFile("splash.jpg", type: "image/jpeg"))
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

        // The `.local` address a zone name would get (as `address` in snapshots, before mDNS may
        // move it to `name-2`), shown under the zone name as a host types it. null if the name
        // has no letters or digits.
        let port = port
        await server.appendRoute("GET /api/local-name") { request in
            let zone = String((request.query["zone"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let address = FriendlyHostname.typedLocalName(forZone: zone).map { "\($0).local" + (port == 80 ? "" : ":\(port)") }
            return try .json(LocalNameReply(address: address))
        }

        // The base playlist past the live Up Next, shown read-only below it (not in snapshots).
        await server.appendRoute("GET /api/upcoming") { request in
            let offset = max(0, Int(request.query["offset"] ?? "") ?? 0)
            let limit = min(100, max(0, Int(request.query["limit"] ?? "") ?? 50))
            return try .json(await session.upcoming(offset: offset, limit: limit))
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
            // With queueing from phones off, only hosts and displays can add.
            if requester.origin == .phone, !(await session.phonesCanQueue), !(await session.isHost(key: body.key)) {
                return HTTPResponse(statusCode: .forbidden)
            }
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
        // Playlists for hosts choosing the base playlist: the hub's library, or (while they type) a
        // search of its music service, as the iPad's own picker offers.
        func hostPlaylists(_ route: HTTPRoute, _ load: @escaping @Sendable (any MusicCatalog, HTTPRequest) async throws -> [PlaylistSummary]) async {
            await server.appendRoute(route) { request in
                guard await session.isHost(key: request.query["key"]) else { return HTTPResponse(statusCode: .forbidden) }
                do {
                    return try .json(try await load(await session.catalog, request))
                } catch {
                    return .serviceFailed(error)
                }
            }
        }
        await hostPlaylists("GET /api/host/playlists") { catalog, _ in try await catalog.libraryPlaylists() }
        await hostPlaylists("GET /api/host/playlists/search") { catalog, request in
            let term = request.query["q"]?.trimmingCharacters(in: .whitespaces) ?? ""
            return term.isEmpty ? [] : try await catalog.searchPlaylists(String(term.prefix(100)))
        }

        await server.appendRoute("POST /api/host/playlist") { request in
            let body = try JSONDecoder.api.decode(PlaylistBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            do {
                // Shuffled before anything plays, so the first song is random too.
                try await session.load(playlist: body.playlist, shuffled: body.shuffle == true)
                if body.play == true { try await session.play() }
            } catch {
                return .serviceFailed(error)
            }
            // Which songs were left out, as in snapshots, so the page can say so straight away.
            let snapshot = await session.snapshot()
            return try .json(PlaylistLoaded(skippedOnLoad: snapshot.skippedOnLoad ?? 0, skippedTitles: snapshot.skippedTitles ?? []))
        }

        await server.appendRoute("POST /api/host/settings") { request in
            let body = try JSONDecoder.api.decode(SettingsBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            await session.applyHostSettings(
                zoneName: body.zoneName?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40).description,
                phonesCanQueue: body.phonesCanQueue,
                phonesCanReorder: body.phonesCanReorder,
                displaysCanControl: body.displaysCanControl,
                wifi: body.wifi.map { WifiDetails(ssid: String($0.ssid.prefix(32)), password: String($0.password.prefix(63)), simpleQR: $0.simpleQR) },
                screensaverWhilePlaying: body.screensaverWhilePlaying
            )
            return HTTPResponse(statusCode: .ok)
        }

        // Settings only hosts see: the Wi‑Fi password, and which displays are connected.
        await server.appendRoute("GET /api/host/details") { request in
            guard await session.isHost(key: request.query["key"]) else { return HTTPResponse(statusCode: .forbidden) }
            let displays = await session.displays.filter { Date().timeIntervalSince($0.lastSeen) < 30 }
            return try .json(HostDetails(wifi: await session.wifi, displays: displays.map { .init(name: $0.name, kind: $0.kind) },
                                         party: await session.partySaveInfo))
        }

        // Saves the party (songs that played, requests still waiting) as a playlist in the hub's
        // account (mid-party from the settings sheet, or just before ending). Failures say why, so
        // the page can offer a retry.
        await server.appendRoute("POST /api/host/save-playlist") { request in
            let body = try JSONDecoder.api.decode(SavePlaylistBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            do {
                let count = try await session.savePartyPlaylist(name: body.name, onlyRequests: body.onlyRequests)
                return try .json(["saved": count])
            } catch {
                let status: HTTPStatusCode = error is PartySaveError ? .conflict : .badGateway
                let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't save the playlist."
                return HTTPResponse(statusCode: status, headers: [.contentType: "application/json"],
                                    body: (try? JSONEncoder().encode(["error": message])) ?? Data())
            }
        }

        // Revokes Host Control from every other phone; this one gets the new key.
        await server.appendRoute("POST /api/host/forget") { request in
            let body = try JSONDecoder.api.decode(HostBody.self, from: await request.bodyData)
            guard await session.isHost(key: body.key) else { return HTTPResponse(statusCode: .forbidden) }
            guard let key = await session.forgetOtherHostPhones() else { return HTTPResponse(statusCode: .notImplemented) }
            return try .json(["key": key])
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

        #if DEBUG
        // Debug builds: the web page's own log (its splash and first screen), for seeing what a
        // real phone did. The page posts lines once `?probe` answers; `GET` reads the log back.
        await server.appendRoute("GET /api/debug/log") { request in
            if request.query["probe"] != nil { return HTTPResponse(statusCode: .noContent) }
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "text/plain; charset=utf-8", .cacheControl: "no-store"],
                                body: WebLog.read())
        }
        await server.appendRoute("POST /api/debug/log") { request in
            WebLog.append(String(decoding: try await request.bodyData.prefix(32_768), as: UTF8.self))
            return HTTPResponse(statusCode: .noContent)
        }
        #endif
    }
}

#if DEBUG
/// Debug builds: the web page's log, at Library/Caches/web.log in the hub app's container.
enum WebLog {
    static let url = URL.cachesDirectory.appending(path: "web.log")
    private static let queue = DispatchQueue(label: "canopymusic.weblog")

    /// Each line gets the hub's clock in front. Starts over past 1 MB.
    static func append(_ text: String) {
        let stamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
        let lines = text.split(separator: "\n").map { "\(stamp) \($0)\n" }.joined()
        queue.sync {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < 1_000_000, let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(lines.utf8))
                try? handle.close()
            } else {
                try? Data(lines.utf8).write(to: url)
            }
        }
    }

    static func read() -> Data { queue.sync { (try? Data(contentsOf: url)) ?? Data() } }
}
#endif

// MARK: - API bodies

struct AddBody: Decodable {
    var track: QueueTrack
    var name: String?
    var clientId: String
    /// Host Control key, so a host can add while queueing from phones is off.
    var key: String?
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

struct LocalNameReply: Encodable {
    var address: String?
}

struct PlaylistBody: Decodable {
    var key: String
    var playlist: PlaylistSummary
    var play: Bool?
    /// Shuffles the playlist as it loads (the web pickers' Shuffle switch).
    var shuffle: Bool?
}

struct PlaylistLoaded: Codable {
    var skippedOnLoad: Int
    var skippedTitles: [String]
}

struct HostDetails: Encodable {
    struct Display: Encodable { var name: String; var kind: HubKind }
    var wifi: WifiDetails
    var displays: [Display]
    /// For "Save as playlist": the suggested name, how many songs, and where it saves.
    var party: PartySaveInfo
}

struct SavePlaylistBody: Decodable {
    var key: String
    var name: String
    var onlyRequests: Bool
}

struct SettingsBody: Decodable {
    var wifi: WifiDetails?
    var key: String
    var zoneName: String?
    var phonesCanQueue: Bool?
    var phonesCanReorder: Bool?
    var displaysCanControl: Bool?
    /// Apple TV hubs only.
    var screensaverWhilePlaying: Bool?
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
        HTTPResponse(statusCode: .badGateway, body: Data(ErrorReport.describe(error).utf8))
        #else
        HTTPResponse(statusCode: .badGateway)
        #endif
    }
}
