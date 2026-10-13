import Foundation
import Network
import Observation

/// Spotify Connect speakers announced on the local network (`_spotify-connect._tcp`): Sonos,
/// receivers and the like. They only reach Spotify's Web API (and so the device list) once a
/// Spotify app has handed them an account over the LAN, which apps outside Spotify can't do; this
/// lists them so the picker can say how to make one available. Each one describes itself with a
/// read-only `?action=getInfo` request on its announced path (its name, type, and whether an
/// account is signed in on it).
@MainActor
@Observable
final class SpotifyNearbyBrowser {
    struct Speaker: Identifiable, Equatable {
        /// The Bonjour instance name.
        let id: String
        var name: String
        /// Spotify's device type (e.g. "AVR", "Speaker"), when the speaker said.
        var type: String?
        /// A Spotify account is signed in on it (it may still be another account's). Sonos reports
        /// none even while playing.
        var hasActiveUser: Bool
        /// The speaker's Spotify device id, when it said (expected to match the Web API's id).
        var deviceID: String? = nil

        /// Whether this is one of the devices Spotify's Web API lists: the same device id, or the
        /// same name, or the room in its name ("Sonos Beam (Bedroom)" is listed as "Bedroom").
        func isListed(id listedID: String, name listedName: String) -> Bool {
            if let deviceID, deviceID.caseInsensitiveCompare(listedID) == .orderedSame { return true }
            let listed = listedName.trimmingCharacters(in: .whitespaces).lowercased()
            let own = name.lowercased()
            if own == listed { return true }
            if let open = own.lastIndex(of: "("), let close = own.lastIndex(of: ")"), open < close {
                let room = own[own.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                if room == listed { return true }
            }
            return false
        }
    }

    private(set) var speakers: [Speaker] = []
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var asked: Set<String> = []

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_spotify-connect._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        asked = []
        speakers = []
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var present: Set<String> = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            present.insert(name)
            if !speakers.contains(where: { $0.id == name }) {
                speakers.append(Speaker(id: name, name: Self.fallbackName(name), type: nil, hasActiveUser: false))
            }
            guard !asked.contains(name) else { continue }
            asked.insert(name)
            var path = "/"
            if case let .bonjour(txt) = result.metadata, let cpath = txt["CPath"], !cpath.isEmpty { path = cpath }
            Task { [weak self] in
                guard let info = await Self.info(endpoint: result.endpoint, path: path) else { return }
                self?.apply(info, to: name)
            }
        }
        speakers.removeAll { !present.contains($0.id) }
        asked.formIntersection(present)
    }

    private func apply(_ info: Info, to id: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        if let name = info.remoteName, !name.isEmpty { speakers[index].name = name }
        speakers[index].type = info.deviceType
        speakers[index].hasActiveUser = !(info.activeUser ?? "").isEmpty
        speakers[index].deviceID = info.deviceID
        #if DEBUG
        print("[nearby] \(info.remoteName ?? id) type=\(info.deviceType ?? "?") id=\(info.deviceID ?? "?") activeUser=\(info.activeUser?.isEmpty == false)")
        #endif
    }

    /// The instance name minus the hex prefix some speakers put in front of it
    /// ("0005cdd759aeDenon X4500H" → "Denon X4500H"); Sonos's raw names are just "Sonos speaker".
    static func fallbackName(_ instance: String) -> String {
        if instance.lowercased().hasPrefix("sonos") { return "Sonos speaker" }
        let hex = instance.prefix(12)
        if instance.count > 12, hex.allSatisfy(\.isHexDigit) { return String(instance.dropFirst(12)) }
        return instance
    }

    fileprivate struct Info: Decodable, Sendable {
        var remoteName: String?
        var deviceType: String?
        var activeUser: String?
        var deviceID: String?
    }

    /// `GET {path}?action=getInfo` over a plain connection to the announced service (3 s limit).
    private nonisolated static func info(endpoint: NWEndpoint, path: String) async -> Info? {
        await withCheckedContinuation { continuation in
            InfoRequest(endpoint: endpoint, path: path) { continuation.resume(returning: $0) }.start()
        }
    }
}

/// One getInfo request. All its state is touched only on its own serial queue.
private final class InfoRequest: @unchecked Sendable {
    private let connection: NWConnection
    private let path: String
    private let queue = DispatchQueue(label: "canopymusic.spotify-nearby")
    private let done: @Sendable (SpotifyNearbyBrowser.Info?) -> Void
    private var finished = false
    private var received = Data()

    init(endpoint: NWEndpoint, path: String, done: @escaping @Sendable (SpotifyNearbyBrowser.Info?) -> Void) {
        connection = NWConnection(to: endpoint, using: .tcp)
        self.path = path
        self.done = done
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let request = "GET \(path)?action=getInfo HTTP/1.0\r\nHost: speaker\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { [self] error in
                    if error != nil { finish(nil) } else { receive() }
                })
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [self] in finish(parse()) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data { received.append(data) }
            if received.count > 262_144 { finish(nil); return }
            if isComplete || error != nil { finish(parse()); return }
            receive()
        }
    }

    private func parse() -> SpotifyNearbyBrowser.Info? {
        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return try? JSONDecoder().decode(SpotifyNearbyBrowser.Info.self, from: received[split.upperBound...])
    }

    private func finish(_ info: SpotifyNearbyBrowser.Info?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        done(info)
    }
}
