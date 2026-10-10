import CanopyCore
import CanopyServer
import Foundation

// Runs the phone web app against the demo catalog on this Mac, for working on the web UI
// without an iPad. `swift run CanopyDevServer` then open http://localhost:8080.

let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
try await session.start(playlist: PlaylistSummary(id: "demo-party", name: "House party", kind: .library), shuffle: false)
session.add(DemoCatalog.track(9), by: Requester(name: "Jamie", clientID: "demo-jamie", origin: .phone))
session.add(DemoCatalog.track(16), by: Requester(name: nil, clientID: nil, origin: .ipad))

guard let (server, task) = await PartyServer.start(session: session) else { fatalError("No port available") }
let hostname = FriendlyHostname(name: "canopymusic")
let ip = LocalNetwork.lanAddress() ?? "127.0.0.1"
let registered = hostname.register(address: ip)
print("Canopy dev server: \(server.url(host: "localhost")!) · LAN \(server.url(host: ip)!)")
print(registered ? "Also at \(server.url(host: hostname.hostname)!)" : "mDNS hostname registration failed")
try await task.value
