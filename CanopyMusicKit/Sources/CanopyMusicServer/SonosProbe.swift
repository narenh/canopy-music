import CanopyMusicCore
import Foundation

/// Debug probe (`-sonosProbe`): finds the Sonos household and writes everything it can read to
/// Library/Caches/sonos.log, for checking what a real household's firmware exposes. Read-only:
/// it sends only `SonosRequest.readOnlyActions` and plain GETs.
@MainActor
public final class SonosProbe {
    public static var logURL: URL { URL.cachesDirectory.appending(path: "sonos.log") }

    private let household: SonosHousehold
    private let transport: any SonosTransport
    private var lines: [String] = []

    public init(household: SonosHousehold) {
        self.household = household
        self.transport = ReadOnlyTransport(base: household.transport)
    }

    /// Waits for discovery (up to `seconds`), then logs. Returns the log's location.
    @discardableResult
    public func run(waitingUpTo seconds: Double = 8) async -> URL {
        try? FileManager.default.removeItem(at: Self.logURL)
        write("Canopy Music Sonos probe, \(Date().formatted(.iso8601))")
        household.log = { [weak self] line in self?.write("  [household] \(line)") }
        household.start()
        let deadline = Date().addingTimeInterval(seconds)
        while household.players.isEmpty || household.isRefreshing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Let a refresh started by late Bonjour results land.
        try? await Task.sleep(for: .seconds(1))
        while household.isRefreshing, Date() < deadline.addingTimeInterval(5) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await logEverything()
        household.log = nil
        write("done")
        return Self.logURL
    }

    private func logEverything() async {
        write("\n== Players (\(household.players.count))")
        for player in household.players {
            write("\(player.roomName) | model \(player.modelName) (\(player.displayName)) | \(player.id) | \(player.host) | sw \(player.softwareVersion ?? "?")")
        }
        write("\n== Groups (\(household.groups.count))")
        for group in household.groups {
            let members = group.members.map { "\($0.roomName) \($0.id)\($0.isInvisible ? " (invisible)" : "")\($0.id == group.coordinatorID ? " [coordinator]" : "")" }
            write("\(group.id): \(members.joined(separator: ", "))")
        }

        write("\n== Music services")
        write("\(household.services.count) available; type list has \(household.serviceTypes.count)")
        for service in SonosMusicService.allCases {
            let listed = household.services.first { $0.name == service.sonosName }
            let sid = listed?.id ?? service.serviceID
            let type = SonosMusicService.serviceType(forServiceID: sid)
            write("\(service.sonosName): sid \(listed.map { "\($0.id)" } ?? "not listed (assuming \(service.serviceID))") auth \(listed?.auth ?? "?") | sid×256+7 = \(type) \(household.serviceTypes.contains(type) ? "is" : "is NOT") in the type list")
        }

        guard let first = household.players.first else {
            write("\nNo players found. Is this device on the same Wi‑Fi as the Sonos, with Local Network access allowed?")
            return
        }
        let client = SonosClient(transport: transport, host: first.host)

        write("\n== /status/accounts (\(first.host))")
        if let data = try? await transport.get(host: first.host, path: "/status/accounts") {
            let text = String(decoding: data, as: UTF8.self)
            let accounts = SonosParse.statusAccounts(data)
            write(accounts.isEmpty ? "No accounts listed. Raw: \(text.prefix(300))" : "")
            for account in accounts {
                write("type \(account.serviceType) (sid \((account.serviceType - 7) / 256)) sn \(account.serial) username \(account.username.map(redact) ?? "none") nickname \(account.nickname ?? "none")")
            }
        } else {
            write("Not available")
        }

        write("\n== Favourites (FV:2)")
        do {
            let favourites = try await client.browse("FV:2")
            if favourites.isEmpty { write("None") }
            for item in favourites { write(describe(item)) }
        } catch {
            write("Browse failed: \(error)")
        }

        write("\n== Saved Sonos playlists (SQ:)")
        if let playlists = try? await client.browse("SQ:") {
            if playlists.isEmpty { write("None") }
            for playlist in playlists.prefix(10) {
                write("\(playlist.title ?? "?") (\(playlist.id))")
                if let items = try? await client.browse(playlist.id, count: 5) {
                    for item in items { write("  " + describe(item)) }
                }
            }
        }

        for group in household.groups {
            guard let host = group.coordinator?.host else { continue }
            let room = SonosClient(transport: transport, host: host)
            write("\n== \(group.name) (coordinator \(group.coordinatorID) at \(host))")
            if let state = try? await room.transportState() { write("transport: \(state.rawValue)") }
            if let media = try? await room.mediaInfo() {
                write("media: \(media["CurrentURI"] ?? "?") tracks=\(media["NrTracks"] ?? "?")")
            }
            if let info = try? await room.positionInfo() {
                write("position: #\(info.track) \(info.position.map { SonosTime.string($0) } ?? "?")/\(info.duration.map { SonosTime.string($0) } ?? "?") uri \(info.trackURI ?? "none")")
                if let item = info.item { write("  now: " + describe(item)) }
            }
            if let queue = try? await room.browse("Q:0", count: 10) {
                write("queue (first \(queue.count)):")
                for item in queue { write("  " + describe(item)) }
            }
        }

        write("\n== Accounts found (\(household.accounts.count))")
        if household.accounts.isEmpty {
            write("None: nothing in favourites, queues or now playing names a service account.")
        }
        for account in household.accounts {
            let name = SonosMusicService(serviceID: account.serviceID)?.sonosName ?? household.services.first { $0.id == account.serviceID }?.name ?? "?"
            write("\(name): sid \(account.serviceID) sn \(account.serialNumber) token \(account.token ?? "none seen") | e.g. \(account.example ?? "?") in \(account.seenIn ?? "favourites")")
        }
        write("Names for accounts: none exposed (no username or nickname in any read-only reply).")

        write("\n== Track URIs Canopy Music would send")
        for service in SonosMusicService.allCases {
            let account = household.accounts(for: service).first
            let reference = SonosTrackReference(service: service, accountSerial: account?.serialNumber ?? 0, token: account?.token)
            let sample = service == .spotify ? "spotify:track:3eXYltBvZSCOs6fM1La6ho" : "1440857781"
            if let uri = try? reference.uri(for: sample) {
                write("\(service.sonosName)\(account == nil ? " (no account found; sn 0 shown)" : ""): \(uri) token \(reference.resolvedToken)")
            }
        }
    }

    private func describe(_ item: SonosItem) -> String {
        var parts = ["\(item.title ?? "?")"]
        if let creator = item.creator { parts.append("by \(creator)") }
        parts.append("id \(item.id)")
        if let uri = item.uri {
            let ids = SonosURI.serviceAndAccount(of: uri)
            parts.append("uri \(uri)")
            if let ids { parts.append("sid \(ids.serviceID) sn \(ids.serial.map(String.init) ?? "none")") }
        }
        if let md = item.resMetadataItemID { parts.append("resMD id \(md)") }
        if let desc = item.desc { parts.append("desc \(desc)") }
        if let kind = item.favoriteDescription { parts.append("(\(kind))") }
        return parts.joined(separator: " | ")
    }

    /// Keeps usernames out of a log that gets sent around.
    private func redact(_ username: String) -> String {
        guard username.count > 2 else { return "***" }
        return "\(username.prefix(1))***\(username.suffix(1)) (\(username.count) chars)"
    }

    private func write(_ line: String) {
        guard !line.isEmpty else { return }
        print("[sonos-probe] \(line)")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: URL.cachesDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.logURL)
        }
    }
}

/// Refuses anything but reads, so the probe can't change a speaker's state by mistake.
private struct ReadOnlyTransport: SonosTransport {
    let base: any SonosTransport

    func send(_ request: SonosRequest) async throws -> [String: String] {
        guard request.isReadOnly else { throw SonosError.upnp(action: request.action, code: nil) }
        return try await base.send(request)
    }

    func get(host: String, path: String) async throws -> Data {
        try await base.get(host: host, path: path)
    }
}
