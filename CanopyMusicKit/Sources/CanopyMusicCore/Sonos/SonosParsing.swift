import Foundation

/// Parsers for what Sonos players answer on port 1400. Each takes the raw response body.
public enum SonosParse {
    // MARK: Device description

    /// `/xml/device_description.xml`. `host` is where it was read from.
    public static func deviceDescription(_ data: Data, host: String) -> SonosPlayer? {
        guard let root = SonosXMLElement.parse(data), let device = root.child("device"),
              let udn = device.value("UDN") else { return nil }
        let id = udn.hasPrefix("uuid:") ? String(udn.dropFirst(5)) : udn
        let model = device.value("modelName") ?? "Sonos"
        return SonosPlayer(
            id: id,
            roomName: device.value("roomName") ?? model,
            modelName: model,
            displayName: device.value("displayName") ?? model,
            host: host,
            softwareVersion: device.value("softwareVersion")
        )
    }

    /// The host in a `Location` URL (`http://10.0.1.161:1400/xml/device_description.xml`).
    public static func host(ofLocation location: String) -> String? {
        URL(string: location)?.host
    }

    // MARK: SOAP

    /// The output arguments of a SOAP reply (`<u:ActionResponse>`'s children), by name. Values
    /// that are themselves XML come back as text, unescaped once.
    public static func soapResponse(_ data: Data) -> [String: String]? {
        guard let root = SonosXMLElement.parse(data), let body = root.child("Body"),
              let response = body.children.first else { return nil }
        if response.localName == "Fault" { return nil }
        var values: [String: String] = [:]
        for child in response.children { values[child.localName] = child.text }
        return values
    }

    /// The UPnP error code of a SOAP fault (e.g. 701 transition not available, 800 not the coordinator).
    public static func soapFaultCode(_ data: Data) -> Int? {
        guard let root = SonosXMLElement.parse(data) else { return nil }
        return root.first("errorCode").flatMap { Int($0.text) }
    }

    // MARK: Topology

    /// `GetZoneGroupState`'s `ZoneGroupState` value (itself XML).
    public static func zoneGroups(_ zoneGroupState: String) -> [SonosGroup] {
        guard let root = SonosXMLElement.parse(zoneGroupState) else { return [] }
        return root.descendants("ZoneGroup").compactMap { group in
            guard let coordinator = group.attributes["Coordinator"] else { return nil }
            let members = group.children("ZoneGroupMember").map { member in
                SonosGroup.Member(
                    id: member.attributes["UUID"] ?? "",
                    roomName: member.attributes["ZoneName"] ?? "",
                    host: member.attributes["Location"].flatMap(host(ofLocation:)),
                    isInvisible: member.attributes["Invisible"] == "1"
                )
            }
            return SonosGroup(id: group.attributes["ID"] ?? coordinator, coordinatorID: coordinator, members: members)
        }
    }

    // MARK: Music services

    /// `ListAvailableServices`: the services this household's region offers (not which are
    /// linked) and the service-type list.
    public static func availableServices(_ reply: [String: String]) -> (services: [SonosServiceDescriptor], types: [Int]) {
        var services: [SonosServiceDescriptor] = []
        if let list = reply["AvailableServiceDescriptorList"], let root = SonosXMLElement.parse(list) {
            services = root.descendants("Service").compactMap { service in
                guard let id = service.attributes["Id"].flatMap(Int.init) else { return nil }
                return SonosServiceDescriptor(id: id, name: service.attributes["Name"] ?? "",
                                              auth: service.child("Policy")?.attributes["Auth"])
            }
        }
        let types = (reply["AvailableServiceTypeList"] ?? "").split(separator: ",").compactMap { Int($0) }
        return (services, types)
    }

    /// The service id `ListAvailableServices` gives a service by name, else its usual id.
    public static func serviceID(for service: SonosMusicService, in services: [SonosServiceDescriptor]) -> Int {
        services.first { $0.name == service.sonosName }?.id ?? service.serviceID
    }

    // MARK: DIDL-Lite

    /// Items in a DIDL-Lite document (a `Browse` result, `TrackMetaData`).
    public static func didlItems(_ didl: String) -> [SonosItem] {
        guard let root = SonosXMLElement.parse(didl) else { return [] }
        return root.children.filter { $0.localName == "item" || $0.localName == "container" }.map(item(from:))
    }

    static func item(from element: SonosXMLElement) -> SonosItem {
        let res = element.child("res")
        var item = SonosItem(
            id: element.attributes["id"] ?? "",
            title: element.value("title"),
            creator: element.value("creator"),
            album: element.value("album"),
            uri: res.flatMap { $0.text.isEmpty ? nil : $0.text },
            duration: SonosTime.seconds(res?.attributes["duration"]),
            upnpClass: element.value("class"),
            desc: element.value("desc"),
            favoriteDescription: element.value("description")
        )
        // A favourite's own metadata, stored escaped inside it.
        if let resMD = element.value("resMD"), let inner = didlItems(resMD).first {
            item.resMetadataItemID = inner.id
            if item.desc == nil { item.desc = inner.desc }
            if item.uri == nil { item.uri = inner.uri }
        }
        return item
    }

    /// `Browse` reply: its `Result` items.
    public static func browseItems(_ reply: [String: String]) -> [SonosItem] {
        didlItems(reply["Result"] ?? "")
    }

    // MARK: Transport

    public static func positionInfo(_ reply: [String: String]) -> SonosPositionInfo {
        let metadata = reply["TrackMetaData"].flatMap { $0 == "NOT_IMPLEMENTED" ? nil : $0 }
        return SonosPositionInfo(
            track: Int(reply["Track"] ?? "") ?? 0,
            trackURI: reply["TrackURI"].flatMap { $0.isEmpty ? nil : $0 },
            duration: SonosTime.seconds(reply["TrackDuration"]),
            position: SonosTime.seconds(reply["RelTime"]),
            item: metadata.flatMap { didlItems($0).first }
        )
    }

    public static func transportState(_ reply: [String: String]) -> SonosTransportState? {
        reply["CurrentTransportState"].flatMap(SonosTransportState.init(rawValue:))
    }

    // MARK: Accounts

    /// The accounts the items show: one per service id and serial number, with the first title
    /// and token seen for it. Items without both are skipped.
    public static func accounts(in items: [SonosItem], seenIn room: String?) -> [SonosAccount] {
        var found: [SonosAccount] = []
        for item in items {
            guard let uri = item.uri, let (sid, sn) = SonosURI.serviceAndAccount(of: uri), let sn else { continue }
            if let index = found.firstIndex(where: { $0.serviceID == sid && $0.serialNumber == sn }) {
                if found[index].token == nil { found[index].token = item.desc }
                continue
            }
            found.append(SonosAccount(serviceID: sid, serialNumber: sn, token: item.desc, example: item.title, seenIn: room))
        }
        return found
    }

    /// Accounts from several sources, first-seen wins for the example; tokens fill in.
    public static func merge(_ lists: [[SonosAccount]]) -> [SonosAccount] {
        var merged: [SonosAccount] = []
        for account in lists.joined() {
            if let index = merged.firstIndex(where: { $0.id == account.id }) {
                if merged[index].token == nil { merged[index].token = account.token }
                if merged[index].example == nil { merged[index].example = account.example; merged[index].seenIn = account.seenIn }
            } else {
                merged.append(account)
            }
        }
        return merged.sorted { ($0.serviceID, $0.serialNumber) < ($1.serviceID, $1.serialNumber) }
    }

    /// `/status/accounts` on older firmware: `<Account Type="…" SerialNum="…"><UN>…</UN><NN>…</NN>`.
    /// Current S2 firmware answers an empty `ZPSupportInfo`, so this usually finds nothing.
    public static func statusAccounts(_ data: Data) -> [(serviceType: Int, serial: Int, username: String?, nickname: String?)] {
        guard let root = SonosXMLElement.parse(data) else { return [] }
        return root.descendants("Account").compactMap { account in
            guard let type = account.attributes["Type"].flatMap(Int.init),
                  let serial = account.attributes["SerialNum"].flatMap(Int.init) else { return nil }
            return (type, serial, account.value("UN"), account.value("NN"))
        }
    }
}
