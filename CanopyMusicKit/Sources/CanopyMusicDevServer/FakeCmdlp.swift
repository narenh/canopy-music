#if DEBUG
import AVFoundation
import CanopyMusicCore
import CoreGraphics
import FlyingFox
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A stand-in for canopy-cmdlp on this Mac (`-fakeCmdlp`), for trying links without the real
/// server: the same API (openapi.yaml), with made-up songs. Any non-empty bearer token works.
///
/// - Links from the five sites resolve after a moment (`slow` in the link: 14 s, so the phone's
///   "still looking" path runs) and "download" over 8 s (`quick`: 2 s; `stuck`: never), queued,
///   then downloading, then converting, with one percentage and ETA across both.
/// - `fail` in the link: the download fails partway. `live`, `blocked`, a playlist or an album
///   link, or another site: refused as cmdlp refuses them.
/// - Audio is a tone (each song its own pitch), 20 s long (`long`: 60 s), as AAC in .m4a, with
///   Range requests, at a signed `audioUrl`.
/// - Each request is printed, `DELETE /zones/{zone}` with how many tracks it had.
actor FakeCmdlp {
    struct Track {
        var api: CmdlpTrack
        var link: String
        var created: Date
        var downloadSeconds: TimeInterval?
        var fails: Bool
        var seconds: Double
        var pitch: Double
    }

    let port: UInt16
    private var tracks: [String: Track] = [:]
    private var audio: [String: Data] = [:]
    private let artwork: Data

    init(port: UInt16) {
        self.port = port
        artwork = Self.artworkJPEG() ?? Data()
    }

    func run() async throws {
        let server = HTTPServer(port: port, logger: .disabled)
        await server.appendRoute("GET /health") { _ in
            Self.json(200, #"{"ok":true,"ytdlp":{"version":"fake"},"tracks":0,"downloading":0,"queued":0}"#)
        }
        await server.appendRoute("GET /artwork/*") { [artwork] _ in
            HTTPResponse(statusCode: .ok, headers: [.contentType: "image/jpeg"], body: artwork)
        }
        await server.appendRoute("POST /resolve") { [self] request in
            guard Self.authorized(request) else { return Self.error(401, "unauthorized", "No bearer token, or the wrong one.") }
            struct Body: Decodable { var url: String; var zone: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: await request.bodyData) else {
                return Self.error(400, "bad_json", "That isn't JSON.")
            }
            print("[fake-cmdlp] POST /resolve \(body.url) in \(body.zone)")
            return await resolve(body.url, zone: body.zone)
        }
        await server.appendRoute("GET /tracks/*") { [self] request in
            guard Self.authorized(request) else { return Self.error(401, "unauthorized", "No bearer token, or the wrong one.") }
            let id = String(request.path.split(separator: "/").last ?? "")
            guard let track = await current(id) else { return Self.error(404, "not_found", "No such track.") }
            return Self.json(200, track)
        }
        await server.appendRoute("GET /audio/*") { [self] request in
            let file = String(request.path.split(separator: "/").last ?? "")
            let id = file.hasSuffix(".m4a") ? String(file.dropLast(4)) : file
            print("[fake-cmdlp] GET /audio/\(id) \(request.headers[HTTPHeader("Range")] ?? "")")
            return await audioResponse(id, signature: request.query["sig"], range: request.headers[HTTPHeader("Range")])
        }
        await server.appendRoute("DELETE /zones/*") { [self] request in
            guard Self.authorized(request) else { return Self.error(401, "unauthorized", "No bearer token, or the wrong one.") }
            let zone = String(request.path.split(separator: "/").last ?? "")
            let deleted = await deleteZone(zone)
            print("[fake-cmdlp] DELETE /zones/\(zone): \(deleted) tracks")
            return Self.json(200, #"{"zone":"\#(zone)","deleted":\#(deleted)}"#)
        }
        print("[fake-cmdlp] at http://127.0.0.1:\(port)")
        try await server.run()
    }

    // MARK: API

    private func resolve(_ link: String, zone: String) async -> HTTPResponse {
        guard let url = URL(string: link), let host = url.host()?.lowercased() else {
            return Self.error(400, "bad_url", "That isn't an http(s) link.")
        }
        let sites = ["youtube.com", "youtu.be", "soundcloud.com", "bandcamp.com", "mixcloud.com", "archive.org"]
        guard sites.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            return Self.error(422, "unsupported_link", "That link isn't from YouTube, SoundCloud, Bandcamp, Mixcloud, or archive.org.")
        }
        let lower = link.lowercased()
        if lower.contains("/sets/") || lower.contains("/album/") || (lower.contains("list=") && !lower.contains("v=")) {
            return Self.error(422, "playlist", "That's a playlist, album, or set, not one track. Paste a link to one song.")
        }
        if lower.contains("live") { return Self.error(422, "live", "That's a live stream. Paste a link to a song or video that has finished.") }
        if lower.contains("blocked") { return Self.error(502, "blocked", "YouTube asked to confirm this isn't a bot. Try again later.") }
        let id = Self.trackID(zone: zone, link: link)
        if var track = tracks[id] {
            // A failed one is tried again.
            if current(id)?.status == .failed {
                track.created = Date()
                track.fails = false
                tracks[id] = track
            }
            return Self.json(200, current(id)!)
        }
        // A lookup takes a moment (YouTube's can take 20 s or more).
        try? await Task.sleep(for: .seconds(lower.contains("slow") ? 14 : 1.5))
        let number = tracks.count + 1
        let seconds: Double = lower.contains("long") ? 60 : 20
        let service = sites.first { host == $0 || host.hasSuffix(".\($0)") }.map(Self.serviceName) ?? "YouTube"
        let api = CmdlpTrack(id: id, zone: zone, status: .pending, title: "Fake Song \(number)", artist: "The Fakes",
                             duration: seconds, artwork: "http://127.0.0.1:\(port)/artwork/\(id).jpg", service: service,
                             stage: "queued", audioUrl: "http://127.0.0.1:\(port)/audio/\(id).m4a?sig=fake-\(id.prefix(6))")
        let download: TimeInterval? = lower.contains("stuck") ? nil : lower.contains("quick") ? 2 : 8
        tracks[id] = Track(api: api, link: link, created: Date(), downloadSeconds: download, fails: lower.contains("fail"),
                           seconds: seconds, pitch: 220 * pow(2, Double(number % 12) / 12))
        return Self.json(200, current(id)!)
    }

    /// The track as it is now: where its made-up download has got to.
    private func current(_ id: String) -> CmdlpTrack? {
        guard let track = tracks[id] else { return nil }
        var api = track.api
        let elapsed = Date().timeIntervalSince(track.created)
        guard let total = track.downloadSeconds else {
            api.stage = "downloading"
            api.progress = .init(percent: 3)
            return api
        }
        if track.fails, elapsed > total / 2 {
            api.status = .failed
            api.stage = nil
            api.error = "ERROR: [youtube] fake: Video unavailable. This video has been removed by the uploader"
        } else if elapsed < total {
            api.stage = elapsed < 1 ? "queued" : elapsed > total - 1 ? "converting" : "downloading"
            // As cmdlp: one percentage and ETA across downloading and converting together.
            api.progress = elapsed < 1 ? nil : .init(percent: elapsed / total * 100, eta: total - elapsed)
        } else {
            api.status = .ready
            api.stage = nil
        }
        return api
    }

    private func deleteZone(_ zone: String) -> Int {
        let ids = tracks.filter { $0.value.api.zone == zone }.map(\.key)
        ids.forEach { tracks[$0] = nil; audio[$0] = nil }
        return ids.count
    }

    private func audioResponse(_ id: String, signature: String?, range: String?) -> HTTPResponse {
        guard let track = tracks[id], let status = current(id)?.status else { return Self.error(404, "not_found", "No such track.") }
        guard signature == "fake-\(id.prefix(6))" else { return Self.error(401, "unauthorized", "No sig, or a wrong one.") }
        switch status {
        case .pending: return Self.error(409, "not_ready", "Still downloading.")
        case .failed: return Self.error(410, "failed", "The download failed.")
        case .ready: break
        }
        let data: Data
        if let made = audio[id] {
            data = made
        } else {
            guard let made = Self.tone(seconds: track.seconds, pitch: track.pitch) else { return HTTPResponse(statusCode: .internalServerError) }
            audio[id] = made
            data = made
        }
        var headers: HTTPHeaders = [.contentType: "audio/mp4", HTTPHeader("Accept-Ranges"): "bytes"]
        guard let range, let (start, end) = Self.byteRange(range, size: data.count) else {
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        }
        headers[HTTPHeader("Content-Range")] = "bytes \(start)-\(end)/\(data.count)"
        return HTTPResponse(statusCode: .partialContent, headers: headers, body: data.subdata(in: start..<(end + 1)))
    }

    // MARK: Helpers

    private static func authorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else { return false }
        return header.count > "Bearer ".count
    }

    private static func json(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: HTTPStatusCode(status, phrase: ""), headers: [.contentType: "application/json"], body: Data(text.utf8))
    }

    private static func json(_ status: Int, _ track: CmdlpTrack) -> HTTPResponse {
        HTTPResponse(statusCode: HTTPStatusCode(status, phrase: ""), headers: [.contentType: "application/json"],
                     body: (try? JSONEncoder().encode(track)) ?? Data())
    }

    private static func error(_ status: Int, _ reason: String, _ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message, "reason": reason])) ?? Data()
        return HTTPResponse(statusCode: HTTPStatusCode(status, phrase: ""), headers: [.contentType: "application/json"], body: body)
    }

    /// 22 characters of base64url, the same for the same link in a zone.
    private static func trackID(zone: String, link: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in "\(zone)|\(link)".utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var id = ""
        var value = hash
        for index in 0..<22 {
            if index == 11 { value = hash &* 0x9E3779B97F4A7C15 }
            id.append(alphabet[Int(value % 64)])
            value /= 64
        }
        return id
    }

    private static func serviceName(_ site: String) -> String {
        switch site {
        case "soundcloud.com": "SoundCloud"
        case "bandcamp.com": "Bandcamp"
        case "mixcloud.com": "Mixcloud"
        case "archive.org": "archive.org"
        default: "YouTube"
        }
    }

    static func byteRange(_ header: String, size: Int) -> (Int, Int)? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]) { return (max(0, size - suffix), size - 1) }
        guard let start = Int(parts[0]), start < size else { return nil }
        let end = Int(parts[1]).map { min($0, size - 1) } ?? size - 1
        return start <= end ? (start, end) : nil
    }

    /// A soft tone, as AAC in an .m4a.
    private static func tone(seconds: Double, pitch: Double) -> Data? {
        let url = FileManager.default.temporaryDirectory.appending(path: "fake-cmdlp-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                     AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]) else { return nil }
        let chunk = AVAudioFrameCount(rate)
        var written = 0
        let total = Int(seconds * rate)
        while written < total {
            let count = min(Int(chunk), total - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                let t = Double(written + frame) / rate
                // A beat every second, so a gap or a jump can be heard.
                let envelope = 0.15 * (0.6 + 0.4 * cos(2 * .pi * t))
                let sample = Float(envelope * sin(2 * .pi * pitch * t))
                buffer.floatChannelData![0][frame] = sample
                buffer.floatChannelData![1][frame] = sample
            }
            guard (try? file.write(from: buffer)) != nil else { return nil }
            written += count
        }
        // Finishes the file (its index), which reading it before would miss.
        file.close()
        return try? Data(contentsOf: url)
    }

    private static func artworkJPEG() -> Data? {
        let size = 600
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.move(to: CGPoint(x: 230, y: 180))
        context.addLine(to: CGPoint(x: 230, y: 420))
        context.addLine(to: CGPoint(x: 430, y: 300))
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
