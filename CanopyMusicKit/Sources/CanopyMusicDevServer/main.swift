import CanopyMusicCore
import CanopyMusicServer
import Foundation

#if DEBUG
// Runs the phone web app against the demo catalog on this Mac, for working on the web UI
// without an iPad. `swift run CanopyMusicDevServer` then open http://localhost:8080.

// `-hostKey <key>`: open http://localhost:8080/?host=<key> for the host pages (the pickers).
// `-tvSetup`: a new Apple TV zone, before its first host has chosen a playlist (the setup sheet).
// The demo catalog's flags work here too (`-lazyCounts`, `-staleCounts`, `-manyPlaylists`).
let args = ProcessInfo.processInfo.arguments
let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
if let i = args.firstIndex(of: "-hostKey"), i + 1 < args.count { session.hostKey = args[i + 1] }
if args.contains("-tvSetup") {
    session.configureHub(kind: .tv, zoneName: "Living Room", serviceName: "Apple Music")
    session.musicAccess = .ok
} else {
    try await session.load(playlist: PlaylistSummary(id: "demo-party", name: "House party", kind: .library))
    try await session.play()
    session.add(DemoCatalog.track(9), by: Requester(name: "Jamie", clientID: "demo-jamie", origin: .phone))
    session.add(DemoCatalog.track(16), by: Requester(name: nil, clientID: nil, origin: .ipad))
}

guard let (server, task) = await PartyServer.start(session: session) else { fatalError("No port available") }
// A host's End Zone (or `-endAfter <seconds>`): the pages are told the zone has ended, as a hub
// tells them, and the server stops.
func endZone() async {
    await server.end()
    print("Zone ended")
    exit(0)
}
session.onStopRequested = { Task { await endZone() } }
if let i = args.firstIndex(of: "-endAfter"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
    Task {
        try? await Task.sleep(for: .seconds(seconds))
        await endZone()
    }
}
let hostname = FriendlyHostname(name: "music-dev")
let ip = LocalNetwork.lanAddress() ?? "127.0.0.1"
let registered = hostname.register(address: ip)
print("Canopy Music dev server: \(server.url(host: "localhost")!) · LAN \(server.url(host: ip)!)")
print(registered ? "Also at \(server.url(host: hostname.hostname)!)" : "mDNS hostname registration failed")
try await task.value
#else
print("CanopyMusicDevServer is a debug-only tool.")
#endif
