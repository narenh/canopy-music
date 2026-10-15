import Foundation

/// What a link being prepared has shown of its download so far (`LinkPrepEstimate`).
struct LinkDownload {
    var first: LinkPrepEstimate.Sample?
    var latest: LinkPrepEstimate.Sample?
    var eta: Double?
}

/// The links being prepared and the failures not yet told, as saved beside the queue.
struct SavedLinkPreparations: Codable {
    var preparing: [LinkPreparation]
    var failures: [String: [LinkFailure]]
}

/// Links pasted on phones (`Links.swift`): looked up at cmdlp, prepared (downloaded) if they
/// aren't already, and queued as the guest's request once they're ready (`LinkPreparation`).
extension PartySession {
    /// The hub takes links (cmdlp's address and token are set). Phones are told, so a pasted
    /// link is looked up rather than searched for.
    public var linksEnabled: Bool { remote == nil && linkService != nil && linkZone != nil }

    func linkServiceChanged() {
        guard remote == nil else { return }
        if linkService == nil { stopLinkPolls() } else { watchPreparations() }
        broadcast()
    }

    /// Links being prepared (restored after a relaunch, or carried over to a rebuilt session)
    /// are watched again. Another cmdlp zone's are dropped: its downloads went with it.
    func watchPreparations() {
        guard let zone = linkZone else { return }
        let elsewhere = linkPreparations.values.filter { $0.zone != nil && $0.zone != zone }.map(\.linkID)
        elsewhere.forEach { linkPreparations[$0] = nil }
        if !elsewhere.isEmpty { saveLinkPreparations() }
        linkPreparations.keys.forEach(watchLink)
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
        // Not over a link being prepared: a lookup kept from before says less than its polls.
        if linkPreparations[found.id] == nil { noteLink(found) }
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

    /// A link a phone picked from its results. Already downloaded, it's queued at once as the
    /// phone's request; still downloading, it's prepared: queued as that request once it's ready,
    /// whatever the phone does meanwhile. Picked again while it's being prepared (by any phone),
    /// that phone follows the same preparation: cmdlp gives the same link the same id, so nothing
    /// downloads twice. Its audio's address is the hub's own record (cmdlp's, if the hub has none:
    /// it relaunched since), never the phone's.
    public func addLink(_ track: QueueTrack, by requester: Requester, id: UUID = UUID()) async throws -> LinkAddResult {
        guard linksEnabled, let service = linkService, let link = track.link else { throw LinkRefusal.unavailable }
        guard engine.canPlayLinks else { throw LinkRefusal.notHere }
        if let progress = joinPreparation(link.id, client: requester.clientID) { return .preparing(progress) }
        var record = linkRecords[link.id]
        if record?.status != .ready {
            // The latest: a download that finished since the lookup queues now, not a poll later.
            do {
                record = try await service.track(id: link.id)
            } catch {
                if record == nil { throw LinkRefusal(resolving: error) }
            }
        }
        // Only this zone's downloads: another zone's go when that zone ends.
        guard let record, record.zone == nil || record.zone == linkZone else { throw LinkRefusal.unavailable }
        guard record.status != .failed else { throw LinkRefusal(Self.failure(record.error, title: nil)) }
        linkRecords[record.id] = record
        // Another phone may have added it while cmdlp was asked.
        if let progress = joinPreparation(record.id, client: requester.clientID) { return .preparing(progress) }
        if record.status == .ready {
            guard record.link.isPlayable else { throw LinkRefusal.unavailable }
            return .queued(mutate { $0.addRequest(record.queueTrack, by: requester, id: id) })
        }
        let preparation = LinkPreparation(linkID: record.id, zone: linkZone, title: record.queueTrack.title, requester: requester,
                                          itemID: id, addedAt: Date(), clients: [requester.clientID].compactMap { $0 })
        linkPreparations[record.id] = preparation
        noteDownload(record)
        saveLinkPreparations()
        watchLink(record.id)
        return .preparing(progress(of: linkPreparations[record.id] ?? preparation))
    }

    /// What a phone hears about the links it added: those still preparing (with how far each has
    /// got), and a sentence for each that failed since it last asked, told once.
    public func linkProgress(for clientID: String) -> LinkProgressReply {
        let preparing = linkPreparations.values.filter { $0.clients.contains(clientID) }.sorted { $0.addedAt < $1.addedAt }
        let failed = linkFailures.removeValue(forKey: clientID) ?? []
        if !failed.isEmpty { saveLinkPreparations() }
        return LinkProgressReply(preparing: preparing.map(progress(of:)), failed: failed)
    }

    /// `client` follows the link being prepared as `cmdlpID`, if it is; nil if it isn't.
    private func joinPreparation(_ cmdlpID: String, client: String?) -> LinkProgress? {
        guard var preparation = linkPreparations[cmdlpID] else { return nil }
        if let client, !preparation.clients.contains(client) {
            preparation.clients.append(client)
            linkPreparations[cmdlpID] = preparation
            saveLinkPreparations()
        }
        return progress(of: preparation)
    }

    func progress(of preparation: LinkPreparation) -> LinkProgress {
        // At most 99 until it's queued: converting comes after the download's 100.
        let percent = linkDownloads[preparation.linkID]?.latest.map { min(99, max(0, Int($0.percent.rounded(.down)))) }
        let takesLong = preparation.takesLong || Date().timeIntervalSince(preparation.addedAt) > LinkPrepEstimate.limit
        return LinkProgress(id: QueueTrack.linkID(preparation.linkID), title: preparation.title, percent: percent, takesLong: takesLong)
    }

    // MARK: Downloads

    /// Checks a link being prepared about once a second until it's queued or failed.
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

    /// One check of a link being prepared. False once there's nothing more to check: queued,
    /// failed, or no longer being prepared.
    func pollLink(_ id: String) async -> Bool {
        guard let service = linkService, linkPreparations[id] != nil else { return false }
        do {
            let track = try await service.track(id: id)
            // Stopped meanwhile (the session was dropped, or links turned off).
            guard !Task.isCancelled, linkService != nil else { return false }
            noteLink(track)
        } catch let error as CmdlpError where error.status == 404 {
            guard !Task.isCancelled else { return false }
            failPreparation(id, reason: "Its download is gone.")
        } catch {
            // cmdlp didn't answer: next time.
        }
        return linkPreparations[id] != nil
    }

    /// cmdlp's latest on a link: a link being prepared is queued once it's ready, dropped (and
    /// its phones told) if it failed, and otherwise its progress noted.
    func noteLink(_ track: CmdlpTrack) {
        guard !linksStopped else { return }
        linkRecords[track.id] = track
        guard linkPreparations[track.id] != nil else { return }
        switch track.status {
        case .ready: queuePrepared(track)
        case .failed: failPreparation(track.id, reason: track.error)
        case .pending: noteDownload(track)
        }
    }

    /// The download's percentage and ETA, for the phones' "Preparing… 37%" and whether it's
    /// expected to take more than 15 seconds (`LinkPrepEstimate`), which once true stays true.
    func noteDownload(_ track: CmdlpTrack, at now: Date = Date()) {
        guard var preparation = linkPreparations[track.id] else { return }
        var download = linkDownloads[track.id] ?? LinkDownload()
        if let percent = track.progress?.percent, percent.isFinite {
            let sample = LinkPrepEstimate.Sample(at: now, percent: percent)
            if download.first == nil { download.first = sample }
            download.latest = sample
        }
        download.eta = track.progress?.eta
        linkDownloads[track.id] = download
        guard !preparation.takesLong,
              LinkPrepEstimate.takesLong(addedAt: preparation.addedAt, first: download.first, latest: download.latest,
                                         eta: download.eta, now: now) else { return }
        preparation.takesLong = true
        linkPreparations[track.id] = preparation
        saveLinkPreparations()
    }

    /// Ready: it joins Up Next as the request of whoever added it first, as when they added it.
    private func queuePrepared(_ track: CmdlpTrack) {
        guard let preparation = linkPreparations[track.id] else { return }
        // The zone moved to a player that can't play links meanwhile (Spotify Connect, say).
        guard engine.canPlayLinks, track.link.isPlayable else {
            failPreparation(track.id, reason: engine.canPlayLinks ? "Ready without an audio address." : "This zone can't play links now.")
            return
        }
        linkPreparations[track.id] = nil
        linkDownloads[track.id] = nil
        mutate { $0.addRequest(track.queueTrack, by: preparation.requester, at: preparation.addedAt, id: preparation.itemID) }
        saveLinkPreparations()
    }

    /// It couldn't be prepared: never queued, and each phone that added it is told once
    /// (`linkProgress(for:)`), even if it comes back to the page later. Nobody else hears of it.
    func failPreparation(_ id: String, reason: String?) {
        guard let preparation = linkPreparations.removeValue(forKey: id) else { return }
        linkDownloads[id] = nil
        let failure = LinkFailure(id: QueueTrack.linkID(id), text: Self.failure(reason, title: preparation.title))
        for client in preparation.clients { linkFailures[client, default: []].append(failure) }
        saveLinkPreparations()
    }

    /// "Couldn’t add “Title”", or for a link pasted again after it failed, "That link couldn't
    /// download". cmdlp's reason (yt-dlp's, with server paths in it) is for the log only.
    static func failure(_ reason: String?, title: String?) -> String {
        #if DEBUG
        if let reason, !reason.isEmpty { print("[links] failed (\(title ?? "a link")): \(reason)") }
        #endif
        return title.map { "Couldn’t add “\($0)”" } ?? "That link couldn't download"
    }

    func stopLinkPolls() {
        linkPolls.values.forEach { $0.cancel() }
        linkPolls = [:]
    }

    /// The zone ended: its downloads stop and its files go at cmdlp (`DELETE /zones/{zone}`),
    /// and nothing of them is kept here, links being prepared included.
    func endLinks() {
        stopLinkPolls()
        linkLookups.values.forEach { $0.cancel() }
        linkLookups = [:]
        linkRecords = [:]
        linkPreparations = [:]
        linkDownloads = [:]
        linkFailures = [:]
        saveLinkPreparations()
        guard let service = linkService, let zone = linkZone else { return }
        Task {
            do {
                try await service.deleteZone(zone)
            } catch {
                ErrorReport.log(error, context: "couldn't delete cmdlp zone \(zone)")
            }
        }
    }

    // MARK: Saving

    /// Where links being prepared are saved: beside the queue's file.
    static func linkPreparationsURL(beside storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: storeURL.deletingPathExtension().lastPathComponent + "-links.json")
    }

    /// Small, and written only when a preparation starts, is joined, ends, or turns slow, so at
    /// once. Not by a session the app has dropped: the one replacing it has the file now.
    func saveLinkPreparations() {
        guard !linksStopped, let storeURL else { return }
        let url = Self.linkPreparationsURL(beside: storeURL)
        guard !linkPreparations.isEmpty || !linkFailures.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = SavedLinkPreparations(preparing: linkPreparations.values.sorted { $0.addedAt < $1.addedAt }, failures: linkFailures)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    func restoreLinkPreparations(beside storeURL: URL) {
        guard let data = try? Data(contentsOf: Self.linkPreparationsURL(beside: storeURL)),
              let saved = try? JSONDecoder().decode(SavedLinkPreparations.self, from: data) else { return }
        linkPreparations = Dictionary(saved.preparing.map { ($0.linkID, $0) }, uniquingKeysWith: { first, _ in first })
        linkFailures = saved.failures
    }
}
