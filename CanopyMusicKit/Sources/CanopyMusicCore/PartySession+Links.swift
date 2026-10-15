import Foundation

/// What happens to a link still downloading when its turn comes, once it has been waited for
/// `PartySession.linkWaitAtTurn` seconds:
/// - The first time, the next song that isn't still downloading plays instead, and the link goes
///   right after it (`QueueState.postponeCurrent`).
/// - With nothing else to play, the music stops on it, and it starts once its download is ready.
/// - The second time (it was put back once already), it's skipped, as a song that couldn't play.
///
/// A link whose download fails leaves the queue at once, wherever it is, with a notice.
enum DownloadingLinkPlan: Equatable {
    case playInstead(QueueItem)
    case waitForIt
    case skipIt
}

/// Links pasted on phones (`Links.swift`): looked up at cmdlp, queued, and watched until their
/// download is ready.
extension PartySession {
    /// The hub takes links (cmdlp's address and token are set). Phones are told, so a pasted
    /// link is looked up rather than searched for.
    public var linksEnabled: Bool { remote == nil && linkService != nil && linkZone != nil }

    func linkServiceChanged() {
        guard remote == nil else { return }
        if linkService == nil { stopLinkPolls() } else { watchQueuedLinks() }
        broadcast()
    }

    /// Links in the queue still downloading (after a relaunch, or a new session for the zone)
    /// are watched again.
    func watchQueuedLinks() {
        for item in [state.current].compactMap({ $0 }) + state.upNext {
            if let link = item.track.link, link.status == .pending { watchLink(link.id) }
        }
    }

    // MARK: Phones

    /// A link a phone pasted, looked up at cmdlp (which starts downloading it), for the phone's
    /// results: the song without its audio's address. nil when the lookup is still running after
    /// `wait` seconds (YouTube can take 20 or more): the phone asks again, and joins it. Throws a
    /// `LinkRefusal` with the sentence for the phone.
    public func resolveLink(_ text: String, waitingAtMost wait: TimeInterval? = nil) async throws -> QueueTrack? {
        let wait = wait ?? linkLookupWait
        guard linksEnabled, let service = linkService, let zone = linkZone, let url = LinkURL.parse(text) else {
            throw LinkRefusal.unavailable
        }
        guard engine.canPlayLinks else { throw LinkRefusal.notHere }
        let key = url.absoluteString
        let lookup: Task<CmdlpTrack, any Error>
        if let running = linkLookups[key] {
            lookup = running
        } else {
            lookup = Task { try await service.resolve(key, zone: zone) }
            linkLookups[key] = lookup
            // Kept a while for a phone asking again; cmdlp answers the same link the same anyway.
            Task { [weak self] in
                _ = try? await lookup.value
                try? await Task.sleep(for: .seconds(120))
                if self?.linkLookups[key] == lookup { self?.linkLookups[key] = nil }
            }
        }
        let found: CmdlpTrack
        do {
            guard let answer = try await Self.answer(of: lookup, within: wait) else { return nil }
            found = answer
        } catch {
            // Asked again, it's looked up again.
            if linkLookups[key] == lookup { linkLookups[key] = nil }
            throw LinkRefusal(resolving: error)
        }
        guard found.status != .failed else { throw LinkRefusal(Self.failure(found.error, title: nil)) }
        noteLink(found)
        return found.queueTrack.forGuests
    }

    /// A lookup's answer, or nil if it hasn't come in `seconds` (it carries on).
    nonisolated static func answer(of lookup: Task<CmdlpTrack, any Error>, within seconds: TimeInterval) async throws -> CmdlpTrack? {
        try await withThrowingTaskGroup(of: CmdlpTrack?.self) { group in
            group.addTask { try await value(of: lookup) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// Queues a link a phone picked from its results, as a request. Its audio's address is the
    /// hub's own record (cmdlp's, if the hub has none: it relaunched since), never the phone's.
    public func addLink(_ track: QueueTrack, by requester: Requester, id: UUID = UUID()) async throws -> AddResult {
        guard linksEnabled, let service = linkService, let link = track.link else { throw LinkRefusal.unavailable }
        guard engine.canPlayLinks else { throw LinkRefusal.notHere }
        var record = linkRecords[link.id]
        if record == nil {
            do {
                record = try await service.track(id: link.id)
            } catch {
                throw LinkRefusal(resolving: error)
            }
        }
        // Only this zone's downloads: another zone's go when that zone ends.
        guard let record, record.zone == nil || record.zone == linkZone else { throw LinkRefusal.unavailable }
        guard record.status != .failed else { throw LinkRefusal(Self.failure(record.error, title: nil)) }
        linkRecords[record.id] = record
        let result = mutate { $0.addRequest(record.queueTrack, by: requester, id: id) }
        if record.status == .pending { watchLink(record.id) }
        return result
    }

    // MARK: Downloads

    /// Checks a queued link's download about once a second until it's ready or failed, or has
    /// left the queue.
    func watchLink(_ id: String) {
        guard linkPolls[id] == nil, linkService != nil else { return }
        linkPolls[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.linkPollInterval ?? .seconds(1))
                guard !Task.isCancelled, let self, await self.pollLink(id) else { break }
            }
            // A cancelled one has already been replaced or dropped.
            if !Task.isCancelled { self?.linkPolls[id] = nil }
        }
    }

    /// One check of a link's download. False once there's nothing more to check: ready, failed,
    /// or no longer queued.
    func pollLink(_ id: String) async -> Bool {
        guard let service = linkService, isLinkQueued(id) else { return false }
        do {
            let track = try await service.track(id: id)
            guard linkService != nil, isLinkQueued(id) else { return false }
            noteLink(track)
            return track.status == .pending
        } catch let error as CmdlpError where error.status == 404 {
            failLink(id, reason: "Its download is gone.")
            return false
        } catch {
            // cmdlp didn't answer: next time.
            return true
        }
    }

    func isLinkQueued(_ id: String) -> Bool {
        state.current?.track.link?.id == id || state.upNext.contains { $0.track.link?.id == id }
    }

    /// cmdlp's latest on a link: the queue's copies show it, a failed one leaves, and a song
    /// waited for starts once it's ready.
    func noteLink(_ track: CmdlpTrack) {
        linkRecords[track.id] = track
        guard track.status != .failed else {
            if isLinkQueued(track.id) { failLink(track.id, reason: track.error) }
            return
        }
        // Each change reaches the phones, and a link that's ready is staged again (with its audio).
        mutate { $0.updateLink(track.link) }
        guard track.status == .ready, let awaiting = awaitingLinkID, let current = state.current, current.id == awaiting,
              current.track.link?.id == track.id else { return }
        awaitingLinkID = nil
        Task { try? await self.serially { await self.playMovingOn(current) } }
    }

    /// A link's download failed (or cmdlp lost it): it leaves Up next, everyone's told why, and a
    /// song waited for gives way to the next.
    func failLink(_ id: String, reason: String?) {
        linkPolls[id]?.cancel()
        linkPolls[id] = nil
        let isCurrent = state.current?.track.link?.id == id
        guard let item = isCurrent ? state.current : state.upNext.first(where: { $0.track.link?.id == id }) else { return }
        var failed = item.track.link ?? LinkTrack(id: id, status: .failed)
        failed.status = .failed
        failed.error = reason
        failed.stage = nil
        failed.percent = nil
        // The current copy says so too, so a wait at its turn ends (`readyLink`).
        mutate {
            $0.updateLink(failed)
            $0.removeLink(id)
        }
        let text = Self.failure(reason, title: item.track.title)
        showSongFailure(text, until: nil)
        showNotice(text)
        guard isCurrent, let awaiting = awaitingLinkID, state.current?.id == awaiting else { return }
        awaitingLinkID = nil
        mutate { $0.dropCurrent() }
        guard let next = state.current else { broadcast(); return }
        Task { try? await self.serially { await self.playMovingOn(next) } }
    }

    /// "“Title” couldn't download: <cmdlp's reason>", kept short (yt-dlp's messages can be long).
    static func failure(_ reason: String?, title: String?) -> String {
        let subject = title.map { "“\($0)”" } ?? "That link"
        guard var reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            return "\(subject) couldn't download"
        }
        if reason.hasPrefix("ERROR: ") { reason.removeFirst("ERROR: ".count) }
        // yt-dlp's "[youtube] dQw4w9WgXcQ: " in front says nothing to guests.
        if reason.hasPrefix("["), let close = reason.firstIndex(of: "]"),
           let colon = reason[close...].range(of: ": ") {
            reason = String(reason[colon.upperBound...])
        }
        if reason.count > 120 { reason = String(reason.prefix(117)) + "…" }
        return "\(subject) couldn't download: \(reason)"
    }

    /// Every phone shows it once, for a while (`PartySnapshot.notice`).
    func showNotice(_ text: String) {
        notice = PartyNotice(text: text)
        noticeExpiry?.cancel()
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func stopLinkPolls() {
        linkPolls.values.forEach { $0.cancel() }
        linkPolls = [:]
    }

    /// The zone ended: its downloads stop and its files go at cmdlp (`DELETE /zones/{zone}`),
    /// and nothing of them is kept here.
    func endLinks() {
        stopLinkPolls()
        linkLookups.values.forEach { $0.cancel() }
        linkLookups = [:]
        linkRecords = [:]
        postponedLinks = []
        awaitingLinkID = nil
        noticeExpiry?.cancel()
        noticeExpiry = nil
        notice = nil
        guard let service = linkService, let zone = linkZone else { return }
        Task {
            do {
                try await service.deleteZone(zone)
            } catch {
                ErrorReport.log(error, context: "couldn't delete cmdlp zone \(zone)")
            }
        }
    }

    // MARK: Its turn

    /// The current song `item`, a link, once its download is ready, with its audio's address.
    /// One still downloading is waited for up to `linkWaitAtTurn` (the song before stops
    /// meanwhile), then `LinkPlaybackError.notReady`; a failed one throws `.failed`; the queue
    /// moving on meanwhile throws `CancellationError`.
    func readyLink(_ item: QueueItem) async throws -> QueueTrack {
        let generation = generation
        let deadline = Date().addingTimeInterval(linkWaitAtTurn)
        var paused = false
        while true {
            guard generation == self.generation, let current = state.current, current.id == item.id else { throw CancellationError() }
            guard let link = current.track.link else { return current.track }
            if link.isPlayable { return current.track }
            if link.status == .failed { throw LinkPlaybackError.failed(link.error) }
            watchLink(link.id)
            guard Date() < deadline else { throw LinkPlaybackError.notReady }
            if !paused, engine.isPlaying {
                engine.pause()
                paused = true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// What to do with `item`, the current song, a link still downloading at its turn
    /// (`DownloadingLinkPlan`).
    func planForDownloadingLink(_ item: QueueItem) -> DownloadingLinkPlan {
        guard state.current?.id == item.id else { return .skipIt }
        if !postponedLinks.contains(item.id), mutate({ $0.postponeCurrent() }), let next = state.current {
            postponedLinks.insert(item.id)
            return .playInstead(next)
        }
        guard state.upNext.contains(where: { $0.track.link?.status != .pending }) else {
            awaitingLinkID = item.id
            if let id = item.track.link?.id { watchLink(id) }
            return .waitForIt
        }
        return .skipIt
    }
}
