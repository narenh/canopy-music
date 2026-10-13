@testable import CanopyMusicCore
import Foundation
import Testing

/// Which SF Symbol a hub or display gets, given which symbol names this OS has.
@MainActor
@Suite struct DeviceSymbolTests {
    func symbol(_ device: String?, kind: HubKind = .ipad, available: Set<String>) -> String {
        DeviceSymbol.name(kind: kind, device: device) { available.contains($0) }
    }

    /// Everything exists: the plain name wins over any generation.
    @Test func prefersTheNameWithoutAGeneration() {
        let all: Set<String> = ["macbook", "macbook.gen1", "macbook.gen2", "macpro", "macpro.gen1", "macpro.gen2", "macpro.gen3",
                                "macmini", "macstudio", "desktopcomputer", "laptopcomputer", "ipad.landscape", "tv"]
        #expect(symbol("MacBookAir", available: all) == "macbook")
        #expect(symbol("MacBookPro", available: all) == "macbook")
        #expect(symbol("iMac", available: all) == "desktopcomputer")
        #expect(symbol("Macmini", available: all) == "macmini")
        #expect(symbol("MacStudio", available: all) == "macstudio")
        #expect(symbol("MacPro", available: all) == "macpro")
        #expect(symbol("Mac", available: all) == "desktopcomputer")
    }

    /// No plain name: the latest generation, not the first.
    @Test func fallsBackToTheLatestGeneration() {
        let gens: Set<String> = ["macbook.gen1", "macbook.gen2", "macpro.gen1", "macpro.gen2", "macpro.gen3", "desktopcomputer", "laptopcomputer"]
        #expect(symbol("MacBookPro", available: gens) == "macbook.gen2")
        #expect(symbol("MacPro", available: gens) == "macpro.gen3")
        #expect(symbol("MacPro", available: ["macpro.gen1", "macpro.gen2", "desktopcomputer"]) == "macpro.gen2")
    }

    /// An older OS without the Mac symbols at all: generic computers.
    @Test func fallsBackToGenericComputers() {
        let old: Set<String> = ["desktopcomputer", "laptopcomputer", "ipad.landscape", "tv"]
        #expect(symbol("MacBookAir", available: old) == "laptopcomputer")
        #expect(symbol("Macmini", available: old) == "desktopcomputer")
        #expect(symbol("MacStudio", available: old) == "desktopcomputer")
        #expect(symbol("MacPro", available: old) == "desktopcomputer")
        // Even with nothing known to exist, there's an answer.
        #expect(symbol("MacBookAir", available: []) == "laptopcomputer")
    }

    @Test func iPadsAndTVsKeepTheirSymbols() {
        #expect(symbol(nil, kind: .ipad, available: ["ipad.landscape", "macbook"]) == "ipad.landscape")
        #expect(symbol(nil, kind: .tv, available: ["tv"]) == "tv")
        // A TV never says it's a Mac; if a peer somehow did, the kind wins.
        #expect(symbol("MacBookAir", kind: .tv, available: ["tv", "macbook"]) == "tv")
        #expect(symbol("", kind: .ipad, available: ["ipad.landscape"]) == "ipad.landscape")
    }

    /// A Mac kind this build doesn't know (from a newer peer) is still some Mac.
    @Test func unknownMacKindIsAMac() {
        #expect(MacKind(wire: "MacCube") == .mac)
        #expect(MacKind(wire: nil) == nil)
        #expect(MacKind(wire: "") == nil)
        #expect(MacKind(wire: "MacBookAir") == .macBookAir)
        #expect(MacKind.macMini.noun == "Mac mini")
        #expect(symbol("MacCube", available: ["desktopcomputer", "macbook"]) == "desktopcomputer")
    }

    /// Snapshots carry the hub's Mac kind; ones from older hubs (without it) still decode.
    @Test func snapshotsCarryTheHubDevice() throws {
        let base = """
        {"version": 1, "upNext": [], "playback": {"isPlaying": false, "position": 0, "capturedAt": 0},
         "canReorder": true, "hubKind": "ipad"
        """
        let old = try JSONDecoder().decode(PartySnapshot.self, from: Data((base + "}").utf8))
        #expect(old.hubKind == .ipad)
        #expect(old.hubDevice == nil)
        let mac = try JSONDecoder().decode(PartySnapshot.self, from: Data((base + ", \"hubDevice\": \"MacStudio\"}").utf8))
        #expect(mac.hubDevice == "MacStudio")

        let display = PartySession(remote: RecordingRemote(clientID: "kitchen"))
        display.apply(mac)
        #expect(display.hubDevice == "MacStudio")
        display.apply(old, force: true)
        #expect(display.hubDevice == nil)
    }

    /// A hub's own snapshot says which Mac it is, and leaves the field out otherwise.
    @Test func hubsSayWhichMacTheyAre() throws {
        let hub = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine())
        hub.configureHub(kind: .ipad, device: "MacBookAir", id: "mac-1", zoneName: "Study", serviceName: nil)
        let sent = try JSONDecoder().decode(PartySnapshot.self, from: JSONEncoder().encode(hub.snapshot()))
        #expect(sent.hubDevice == "MacBookAir")
        let ipad = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine())
        ipad.configureHub(kind: .ipad, id: "ipad-1", zoneName: "Kitchen", serviceName: nil)
        let json = String(decoding: try JSONEncoder().encode(ipad.snapshot()), as: UTF8.self)
        #expect(!json.contains("hubDevice"))
    }
}
