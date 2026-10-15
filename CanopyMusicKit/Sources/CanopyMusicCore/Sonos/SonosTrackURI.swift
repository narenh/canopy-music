import Foundation

/// How Sonos names a service's track: the URI a queue entry plays and the DIDL-Lite metadata
/// sent with it (`AddURIToQueue`).
///
/// Spotify's shape is the one a real S2 household's queue holds
/// (`x-sonos-spotify:spotify%3atrack%3a{id}?sid=12&flags=8232&sn=4`). Apple Music's is the
/// community-documented one and hasn't been seen on a real household yet:
/// `x-sonos-http:song%3a{id}.mp4?sid=204&flags=8224&sn={sn}`. The item-id prefixes and the `desc`
/// token form (`SA_RINCON{type}_X_#Svc{type}-0-Token`) are community-documented too; the token's
/// form matches what this household's Sonos Radio favourites carry.
public struct SonosTrackReference: Hashable, Sendable {
    public var service: SonosMusicService
    /// The account's serial number in the household (`sn`).
    public var accountSerial: Int
    /// The `desc` to send; nil uses the generic `-0-` token for the service.
    public var token: String?

    public init(service: SonosMusicService, accountSerial: Int, token: String? = nil) {
        self.service = service
        self.accountSerial = accountSerial
        self.token = token
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// Not a track id this service's Sonos URIs can carry (a Spotify episode or local file, a
        /// library id given as a catalog id, a library song on a Spotify zone).
        case unsupportedTrack(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedTrack: "This song can't be played on Sonos."
            }
        }
    }

    /// The bare service track id: Apple Music's catalog id ("1440857781"), or Spotify's base-62 id
    /// from a `spotify:track:…` URI.
    public func serviceTrackID(for trackID: String) throws -> String {
        switch service {
        case .appleMusic:
            // Library-only songs (`i.…`) have no catalog id: they go by `libraryURI(for:)`.
            guard !trackID.isEmpty, trackID.allSatisfy(\.isNumber) else { throw Failure.unsupportedTrack(trackID) }
            return trackID
        case .spotify:
            let parts = trackID.split(separator: ":")
            if parts.count == 3, parts[0] == "spotify", parts[1] == "track" { return String(parts[2]) }
            if parts.count == 1, !trackID.isEmpty, trackID.allSatisfy({ $0.isLetter || $0.isNumber }) { return trackID }
            throw Failure.unsupportedTrack(trackID)
        }
    }

    /// The service's own name for the track, percent-encoded as Sonos writes it (lower-case hex).
    func encodedObject(_ id: String) -> String {
        switch service {
        case .appleMusic: "song%3a\(id)"
        case .spotify: "spotify%3atrack%3a\(id)"
        }
    }

    /// The `flags` value. Spotify's is what the Sonos app wrote into a real queue; Apple Music's
    /// is the community-documented value.
    public var flags: Int {
        switch service {
        case .appleMusic: 8224
        case .spotify: 8232
        }
    }

    public func uri(for trackID: String) throws -> String {
        let id = try serviceTrackID(for: trackID)
        let object = encodedObject(id)
        let query = "sid=\(service.serviceID)&flags=\(flags)&sn=\(accountSerial)"
        switch service {
        case .appleMusic: return "x-sonos-http:\(object).mp4?\(query)"
        case .spotify: return "x-sonos-spotify:\(object)?\(query)"
        }
    }

    /// The DIDL-Lite item id: a prefix Sonos uses for "a track from a music service", then the
    /// encoded object.
    public func itemID(for trackID: String) throws -> String {
        let object = encodedObject(try serviceTrackID(for: trackID))
        switch service {
        case .appleMusic: return "10032020\(object)"
        case .spotify: return "00032020\(object)"
        }
    }

    public var resolvedToken: String {
        token ?? Self.genericToken(serviceType: service.serviceType)
    }

    public static func genericToken(serviceType: Int) -> String {
        "SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token"
    }

    /// The URI for a queue track: a song only in the account's library (`QueueTrack.isLibraryOnly`)
    /// as `libraryURI(for:)`, anything else (a library copy of a catalog song too) as `uri(for:)`
    /// its id.
    public func uri(for track: QueueTrack) throws -> String {
        // A song from a link: cmdlp's signed https address, as it is, whatever the service.
        if let link = track.link {
            guard link.isPlayable, let audio = link.audioURL else { throw LinkPlaybackError.notReady }
            return audio.absoluteString
        }
        guard track.isLibraryOnly, let libraryID = track.libraryID else { return try uri(for: track.id) }
        return try libraryURI(for: libraryID)
    }

    /// An Apple Music library-only song, as the Sonos app sends it (read off a real speaker's
    /// queue, and played that way from the debug Library test):
    /// `x-sonos-http:librarytrack%3a{libraryID}.unknown?sid=204&flags=0&sn={sn}`. Sonos then
    /// reports it as `….mp4?sid=204&flags=8232&sn=…` (`SonosURI.canopyTrackID` reads both).
    public func libraryURI(for libraryID: String) throws -> String {
        guard service == .appleMusic, LibraryArtwork.isLibraryID(libraryID) else { throw Failure.unsupportedTrack(libraryID) }
        return "x-sonos-http:\(Self.libraryObject(libraryID)).unknown?sid=\(service.serviceID)&flags=0&sn=\(accountSerial)"
    }

    static func libraryObject(_ libraryID: String) -> String { "librarytrack%3a\(libraryID)" }

    /// The `EnqueuedURIMetaData` for a track: DIDL-Lite with its title and the service token.
    /// A library-only song's also has the `res` the Sonos app gives it (its URI, with
    /// protocolInfo `sonos.com-http:*:application/octet-stream:*`, and its length).
    public func metadata(for track: QueueTrack) throws -> String {
        let e = SonosXMLEscape.escape
        if let link = track.link { return Self.linkMetadata(track, link: link) }
        let itemID: String
        var res = ""
        if track.isLibraryOnly, let libraryID = track.libraryID {
            let uri = try libraryURI(for: libraryID)
            itemID = "10032020" + Self.libraryObject(libraryID)
            let duration = track.duration.map { " duration=\"\(SonosTime.string($0))\"" } ?? ""
            res = "<res protocolInfo=\"sonos.com-http:*:application/octet-stream:*\"\(duration)>\(e(uri))</res>"
        } else {
            itemID = try self.itemID(for: track.id)
        }
        var item = "<item id=\"\(e(itemID))\" parentID=\"-1\" restricted=\"true\">"
        item += res
        item += "<dc:title>\(e(track.title))</dc:title>"
        if !track.artist.isEmpty { item += "<dc:creator>\(e(track.artist))</dc:creator>" }
        if !track.album.isEmpty { item += "<upnp:album>\(e(track.album))</upnp:album>" }
        item += "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        item += "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">\(e(resolvedToken))</desc>"
        item += "</item>"
        return Self.didlOpen + item + "</DIDL-Lite>"
    }

    /// A song from a link: minimal DIDL-Lite (its title, artist, art, and the music-track class),
    /// no service token, as the debug Link test queued one on a real Sonos room.
    static func linkMetadata(_ track: QueueTrack, link: LinkTrack) -> String {
        let e = SonosXMLEscape.escape
        var item = "<item id=\"\(e("link-\(link.id)"))\" parentID=\"-1\" restricted=\"true\">"
        item += "<dc:title>\(e(track.title))</dc:title>"
        if !track.artist.isEmpty { item += "<dc:creator>\(e(track.artist))</dc:creator>" }
        if let art = track.artworkURL, art.scheme != nil { item += "<upnp:albumArtURI>\(e(art.absoluteString))</upnp:albumArtURI>" }
        item += "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        item += "</item>"
        return didlOpen + item + "</DIDL-Lite>"
    }

    static let didlOpen = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
}

/// Reading Sonos URIs back.
public enum SonosURI {
    /// The `sid` and `sn` query values of a service item URI, if it has them.
    public static func serviceAndAccount(of uri: String) -> (serviceID: Int, serial: Int?)? {
        guard let query = uri.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        var sid: Int?
        var sn: Int?
        // `&` may still be escaped as `&amp;` when read out of raw XML.
        for pair in query.replacingOccurrences(of: "&amp;", with: "&").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "sid": sid = Int(kv[1])
            case "sn": sn = Int(kv[1])
            default: break
            }
        }
        guard let sid else { return nil }
        return (sid, sn)
    }

    /// The track id Canopy Music uses for a service track URI: Spotify's `spotify:track:…` URI,
    /// Apple Music's catalog id, or an Apple Music library-only song's library id ("i.…", its
    /// `QueueTrack.id`), or a link's (`linkTrackID`). nil for anything else (line-in, radio, TV,
    /// Spotify Connect).
    public static func canopyTrackID(of uri: String) -> String? {
        let base = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let decoded = base.removingPercentEncoding ?? base
        if decoded.hasPrefix("x-sonos-spotify:") {
            let rest = decoded.dropFirst("x-sonos-spotify:".count)
            return rest.hasPrefix("spotify:track:") ? String(rest) : nil
        }
        // A library-only song: the form Canopy Music queues (`librarytrack:{id}.unknown`), and the
        // one Sonos rewrites it to once it plays (`librarytrack:{id}.mp4`, flags 8232). The id
        // has a dot of its own ("i.bVl4FRZ1zY"), so only what follows its second is dropped.
        if decoded.hasPrefix("x-sonos-http:librarytrack:") {
            var id = decoded.dropFirst("x-sonos-http:librarytrack:".count)
            if id.hasPrefix("i."), let dot = id.dropFirst(2).firstIndex(of: ".") { id = id[..<dot] }
            return LibraryArtwork.isLibraryID(String(id)) ? String(id) : nil
        }
        // Apple Music: the form Canopy Music queues (`x-sonos-http:song:{id}.mp4`), and the
        // streaming forms Sonos keeps in its queue for the same song (seen on a real S2 household:
        // `x-sonosapi-hls-static:song:{id}`), so a song still reads as ours once Sonos has it.
        for scheme in ["x-sonos-http:song:", "x-sonosapi-hls-static:song:", "x-sonosapi-hls:song:"] where decoded.hasPrefix(scheme) {
            var id = decoded.dropFirst(scheme.count)
            if let dot = id.firstIndex(of: ".") { id = id[..<dot] }
            return id.isEmpty ? nil : String(id)
        }
        return linkTrackID(of: uri)
    }

    /// A song from a link (`QueueTrack.linkID`): cmdlp's `…/audio/{id}.m4a?sig=…`, read by its
    /// path whatever Sonos makes of the rest (another scheme in front, the `.m4a` or the query
    /// gone, escaped), so the engine still takes it for ours. nil for anything else.
    public static func linkTrackID(of uri: String) -> String? {
        let decoded = uri.removingPercentEncoding ?? uri
        guard let marker = decoded.range(of: "/audio/", options: .backwards) else { return nil }
        let rest = decoded[marker.upperBound...]
        let id = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard id.count == 22 else { return nil }
        let after = rest.dropFirst(id.count)
        guard after.isEmpty || after.hasPrefix(".m4a") || after.hasPrefix("?") || after.hasPrefix("&") else { return nil }
        return QueueTrack.linkID(String(id))
    }

    /// The URI that plays a group's queue.
    public static func queue(of coordinatorID: String) -> String { "x-rincon-queue:\(coordinatorID)#0" }

    /// The URI that makes a player join a group.
    public static func joinGroup(of coordinatorID: String) -> String { "x-rincon:\(coordinatorID)" }

    /// The coordinator named by a group member's `x-rincon:{coordinator}` URI (what a member
    /// answers to `GetPositionInfo` and `GetMediaInfo`, checked on a real Move in a Beam's group).
    /// nil for anything else, `x-rincon-queue:` and `x-rincon-stream:` included.
    public static func coordinator(ofMemberURI uri: String) -> String? {
        guard uri.hasPrefix("x-rincon:") else { return nil }
        let id = uri.dropFirst("x-rincon:".count)
        return id.isEmpty ? nil : String(id)
    }
}

/// Sonos's "H:MM:SS" times.
public enum SonosTime {
    /// nil for "NOT_IMPLEMENTED" and other non-times.
    public static func seconds(_ string: String?) -> TimeInterval? {
        guard let string, !string.isEmpty else { return nil }
        let parts = string.split(separator: ":")
        guard parts.count == 3 || parts.count == 2 else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    public static func string(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }
}
