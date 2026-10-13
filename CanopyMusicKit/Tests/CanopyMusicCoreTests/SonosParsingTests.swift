import Foundation
import Testing
@testable import CanopyMusicCore

/// Fixtures are real read-only replies from an S2 household (firmware 97.1 / app 18.8): a Beam
/// and a Move, each its own group, with Spotify linked. `list_available_services.xml` is cut
/// down to five services (the real list has over a hundred); everything else is as received.
enum SonosFixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/Sonos"))
        return try Data(contentsOf: url)
    }

    static func soap(_ name: String) throws -> [String: String] {
        try #require(SonosParse.soapResponse(try data(name)))
    }
}

struct SonosDeviceDescriptionTests {
    @Test func beam() throws {
        let player = try #require(SonosParse.deviceDescription(try SonosFixture.data("device_description_beam"), host: "10.0.1.161"))
        #expect(player.id == "RINCON_347E5C81C63501400")
        #expect(player.roomName == "Sonos Beam (Bedroom)")
        #expect(player.modelName == "Sonos Beam")
        #expect(player.displayName == "Beam")
        #expect(player.host == "10.0.1.161")
        #expect(player.softwareVersion == "97.1-80312")
    }

    @Test func move() throws {
        let player = try #require(SonosParse.deviceDescription(try SonosFixture.data("device_description_move"), host: "10.0.1.224"))
        #expect(player.id == "RINCON_542A1B76A4EC01400")
        #expect(player.roomName == "Sonos Move")
        #expect(player.modelName.hasPrefix("Sonos Move"))
    }

    @Test func notXML() {
        #expect(SonosParse.deviceDescription(Data("<html".utf8), host: "x") == nil)
    }

    @Test func hostFromBonjourLocation() {
        #expect(SonosParse.host(ofLocation: "http://10.0.1.161:1400/xml/device_description.xml") == "10.0.1.161")
    }
}

struct SonosTopologyTests {
    @Test func twoSingleRoomGroups() throws {
        let reply = try SonosFixture.soap("zone_group_state")
        let groups = SonosParse.zoneGroups(try #require(reply["ZoneGroupState"]))
        #expect(groups.count == 2)
        let beam = try #require(groups.first { $0.coordinatorID == "RINCON_347E5C81C63501400" })
        #expect(beam.members.count == 1)
        #expect(beam.name == "Sonos Beam (Bedroom)")
        #expect(beam.coordinator?.host == "10.0.1.161")
        let move = try #require(groups.first { $0.coordinatorID == "RINCON_542A1B76A4EC01400" })
        #expect(move.name == "Sonos Move")
        #expect(move.coordinator?.host == "10.0.1.224")
    }

    @Test func groupedRoomsAndInvisibleMembers() throws {
        let state = """
        <ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:1">\
        <ZoneGroupMember UUID="RINCON_B" Location="http://10.0.0.3:1400/xml/device_description.xml" ZoneName="Kitchen"/>\
        <ZoneGroupMember UUID="RINCON_A" Location="http://10.0.0.2:1400/xml/device_description.xml" ZoneName="Living Room">\
        <Satellite UUID="RINCON_SUB" ZoneName="Living Room" Invisible="1"/></ZoneGroupMember>\
        <ZoneGroupMember UUID="RINCON_C" Location="http://10.0.0.4:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1"/>\
        </ZoneGroup></ZoneGroups></ZoneGroupState>
        """
        let group = try #require(SonosParse.zoneGroups(state).first)
        #expect(group.rooms.map(\.roomName) == ["Living Room", "Kitchen"])
        #expect(group.name == "Living Room + Kitchen")
    }
}

struct SonosServicesTests {
    @Test func appleMusicAndSpotifyIDs() throws {
        let (services, types) = SonosParse.availableServices(try SonosFixture.soap("list_available_services"))
        #expect(services.first { $0.name == "Apple Music" }?.id == 204)
        #expect(services.first { $0.name == "Spotify" }?.id == 12)
        #expect(services.first { $0.id == 256 }?.name == "CBC Radio & Music")
        #expect(SonosParse.serviceID(for: .appleMusic, in: services) == 204)
        #expect(SonosParse.serviceID(for: .spotify, in: []) == 12)
        // sid × 256 + 7, as the real type list confirms.
        #expect(types.contains(SonosMusicService.appleMusic.serviceType))
        #expect(types.contains(SonosMusicService.spotify.serviceType))
        #expect(SonosMusicService.appleMusic.serviceType == 52231)
        #expect(SonosMusicService.spotify.serviceType == 3079)
        #expect(types.contains(SonosMusicService.serviceType(forServiceID: 303)))
    }

    @Test func statusAccountsIsEmptyOnS2() throws {
        #expect(SonosParse.statusAccounts(try SonosFixture.data("status_accounts")).isEmpty)
    }

    @Test func statusAccountsOnOlderFirmware() {
        let xml = """
        <ZPSupportInfo><Accounts LastUpdateDevice="RINCON_X" Version="8" NextSerialNum="5">\
        <Account Type="3079" SerialNum="2" Deleted="1"><UN>someone</UN><NN></NN></Account>\
        <Account Type="3079" SerialNum="4"><UN>redacted</UN><NN>Room mate</NN></Account>\
        </Accounts></ZPSupportInfo>
        """
        let accounts = SonosParse.statusAccounts(Data(xml.utf8))
        #expect(accounts.count == 2)
        #expect(accounts[1].serviceType == 3079)
        #expect(accounts[1].serial == 4)
        #expect(accounts[1].nickname == "Room mate")
    }
}

struct SonosBrowseTests {
    @Test func favouritesAreSonosRadioShortcuts() throws {
        let items = SonosParse.browseItems(try SonosFixture.soap("browse_favorites"))
        #expect(items.count == 3)
        #expect(items[0].title == "Discover Sonos Radio")
        #expect(items[0].favoriteDescription == "Sonos Radio")
        #expect(items[0].desc == "SA_RINCON77575_X_#Svc77575-0-Token")
        #expect(items[0].resMetadataItemID?.hasPrefix("10fe3064") == true)
        // Shortcuts carry no URI, so no account.
        #expect(SonosParse.accounts(in: items, seenIn: nil).isEmpty)
    }

    @Test func queueNamesTheSpotifyAccount() throws {
        let items = SonosParse.browseItems(try SonosFixture.soap("browse_queue"))
        #expect(items.count == 3)
        #expect(items[0].title == "KGB")
        #expect(items[0].creator == "ADÉLA")
        #expect(items[0].album == "PRIMA")
        #expect(items[0].duration == 158)
        #expect(items[0].uri == "x-sonos-spotify:spotify%3atrack%3a3eXYltBvZSCOs6fM1La6ho?sid=12&flags=8232&sn=4")
        let accounts = SonosParse.accounts(in: items, seenIn: "Sonos Move")
        #expect(accounts == [SonosAccount(serviceID: 12, serialNumber: 4, example: "KGB", seenIn: "Sonos Move")])
    }

    @Test func mergingAccounts() {
        let a = SonosAccount(serviceID: 12, serialNumber: 4, example: "KGB", seenIn: "Move")
        let b = SonosAccount(serviceID: 12, serialNumber: 4, token: "SA_RINCON3079_X_#Svc3079-abc-Token")
        let c = SonosAccount(serviceID: 12, serialNumber: 2, example: "Other")
        let d = SonosAccount(serviceID: 204, serialNumber: 1)
        let merged = SonosParse.merge([[a], [d, b, c]])
        #expect(merged.map(\.id) == ["12:2", "12:4", "204:1"])
        #expect(merged[1].token == "SA_RINCON3079_X_#Svc3079-abc-Token")
        #expect(merged[1].example == "KGB")
    }
}

struct SonosTransportReplyTests {
    @Test func positionInQueue() throws {
        let info = SonosParse.positionInfo(try SonosFixture.soap("position_info_queue"))
        #expect(info.track == 1)
        #expect(info.duration == 158)
        #expect(info.position != nil)
        #expect(info.trackURI == "x-sonos-spotify:spotify%3atrack%3a3eXYltBvZSCOs6fM1La6ho?sid=12&flags=8232&sn=4")
        #expect(info.item?.title == "KGB")
        #expect(SonosURI.canopyTrackID(of: try #require(info.trackURI)) == "spotify:track:3eXYltBvZSCOs6fM1La6ho")
    }

    @Test func positionOnSpotifyConnect() throws {
        let info = SonosParse.positionInfo(try SonosFixture.soap("position_info_spotify_connect"))
        #expect(info.duration == nil)
        #expect(info.position == nil)
        #expect(info.item == nil)
        #expect(info.trackURI?.hasPrefix("x-sonos-vli:") == true)
        #expect(SonosURI.canopyTrackID(of: try #require(info.trackURI)) == nil)
    }

    @Test func transportState() throws {
        #expect(SonosParse.transportState(try SonosFixture.soap("transport_info")) == .paused)
    }

    @Test func faultCode() {
        let fault = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode>\
        <faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">\
        <errorCode>800</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """
        #expect(SonosParse.soapResponse(Data(fault.utf8)) == nil)
        #expect(SonosParse.soapFaultCode(Data(fault.utf8)) == 800)
    }

    @Test func times() {
        #expect(SonosTime.seconds("0:02:38") == 158)
        #expect(SonosTime.seconds("1:00:01") == 3601)
        #expect(SonosTime.seconds("NOT_IMPLEMENTED") == nil)
        #expect(SonosTime.seconds(nil) == nil)
        #expect(SonosTime.string(158.9) == "0:02:38")
        #expect(SonosTime.string(3601) == "1:00:01")
        #expect(SonosTime.string(-4) == "0:00:00")
    }
}
