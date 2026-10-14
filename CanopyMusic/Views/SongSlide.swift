import CanopyMusicCore
import SwiftUI

// Shared with the TV target (a symlink there).

/// The party screens' song change (the iPad's and Mac's `NowPlayingView`, the Apple TV's
/// `TVPartyView`): each song is one page (its art, text and progress), and when the song changes
/// (a skip, a phone, or the song ending) the new song's page pushes the old one's out sideways,
/// like turning a page. Each screen lays out its own page (`SongPages`) and keeps whatever else
/// goes with the song (the background, the controls below) to the one shown (`current(in:)`).
@MainActor @Observable
final class SongSlider {
    /// The song the page shows, until it slides on to the session's current one.
    private(set) var shown: QueueItem?
    private var started = false
    /// Which way the last slide went: forward brings the new song in from the right.
    private var forward = true
    /// A slide is under way.
    private(set) var isSliding = false
    /// When the slide under way finishes.
    @ObservationIgnored private var slideEnds: ContinuousClock.Instant?
    /// Counts the slides, so only the last one's end says none is under way.
    @ObservationIgnored private var slides = 0

    static let duration = 0.5
    /// Fast at first, then slowing to a stop: the pages arrive and settle (an ease-out quint).
    static let animation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: duration)

    /// The song to show: the live item while it's the one shown, so its changes (a requester's
    /// name) show.
    func current(in session: PartySession) -> QueueItem? {
        let live = session.nowPlaying
        return !started || shown?.id == live?.id ? live : shown
    }

    /// How far the page coming in starts, and the one going out goes: right when positive.
    /// Far enough that the song going out ends past the screen's left edge (shadow and all), and
    /// the one coming in starts behind Up next.
    func offset(in session: PartySession, columnWidth: CGFloat) -> CGFloat {
        // The song shown leaves the way the change to the live one goes, so that's set while it's
        // still shown; the song coming in arrives the way `showCurrent` set.
        let goesForward = started && shown?.id != session.nowPlaying?.id ? slidesForward(from: shown, in: session) : forward
        return (columnWidth + 160) * (goesForward ? 1 : -1)
    }

    /// Whether going from `item` to the session's current song is a step forward. Going back puts
    /// the song that was playing at the top of Up next; anything else (a skip, the song ending, a
    /// jump in the queue) counts as forward.
    private func slidesForward(from item: QueueItem?, in session: PartySession) -> Bool {
        guard let item else { return true }
        return session.state.upNext.first?.id != item.id
    }

    /// Slides from the shown song to the session's current one. A change during a slide waits for
    /// it to finish (a moment), then slides once straight to the newest song: never two slides at
    /// once, and songs skipped past in between never show.
    func showCurrent(in session: PartySession, artBucket: Int, log: (String) -> Void) async {
        guard started else {
            shown = session.nowPlaying
            started = true
            return
        }
        if let slideEnds {
            do { try await Task.sleep(until: slideEnds, clock: .continuous) } catch { return }
        }
        guard shown?.id != session.nowPlaying?.id else { return }
        // The new song's art is loaded before it slides in (the pre-warm of the next songs' has
        // usually loaded it already); after a moment it slides anyway, and the art shows when
        // it's loaded.
        if let url = ArtworkURL.url(for: session.nowPlaying?.track, large: true) {
            let start = ContinuousClock.now
            let ready = await ArtworkCache.shared.ready(url, bucket: artBucket, within: .milliseconds(300))
            log("artwork \(ready ? "ready" : "not ready") after \(ContinuousClock.now - start) (\(artBucket) px)")
            if Task.isCancelled { return }
        }
        let goingForward = slidesForward(from: shown, in: session)
        slideEnds = .now + .seconds(Self.duration)
        slides += 1
        let slide = slides
        // Both pages move in this one animation, so they stay together.
        withAnimation(Self.animation) {
            forward = goingForward
            shown = session.nowPlaying
            isSliding = true
        }
        // Not the animation's completion: that waits for everything else that changed with the
        // song too (the iPad's background takes 2 s).
        Task {
            try? await Task.sleep(for: .seconds(Self.duration))
            if slides == slide { isSliding = false }
        }
    }
}

/// The song's page, sliding to the next song's when it changes (`SongSlider`). `page` lays out one
/// song's page; give it a fixed width, and clip the column where the slide should show.
struct SongPages<Page: View>: View {
    let slider: SongSlider
    let session: PartySession
    /// The now-playing column's width, edge to edge: the slide's distance.
    let columnWidth: CGFloat
    /// The size bucket the page's art decodes at (`ArtworkSizing`), for loading it ahead.
    let artBucket: Int
    var log: (String) -> Void = { _ in }
    @ViewBuilder let page: (QueueItem?) -> Page

    var body: some View {
        let current = slider.current(in: session)
        ZStack {
            page(current)
                .id(current?.id)
                .transition(SongSlide(offset: slider.offset(in: session, columnWidth: columnWidth)))
        }
        // A newer change cancels this one part way, and `showCurrent` goes on to the newest song.
        .task(id: session.nowPlaying?.id) { await slider.showCurrent(in: session, artBucket: artBucket, log: log) }
        // The next song or two's art at Now Playing size, loaded ahead so the slide to it has it
        // (`showCurrent` waits only a moment). Just those: every row's would cost as much again
        // as the whole list of rows many times over, and most of them get skipped or reordered.
        .task(id: prewarm) { ArtworkCache.shared.prewarm(prewarm.urls, bucket: prewarm.bucket) }
    }

    private struct Prewarm: Equatable {
        let urls: [URL]
        let bucket: Int
    }

    /// The first two Up next songs' big images, at the Now Playing size.
    private var prewarm: Prewarm {
        Prewarm(urls: session.state.upNext.prefix(2).compactMap { ArtworkURL.url(for: $0.track, large: true) }, bucket: artBucket)
    }
}

/// The now-playing page turn: the new song comes in from `offset` (right when it's positive)
/// while the old one goes out the other way, the same distance.
struct SongSlide: Transition {
    let offset: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.offset(x: phase == .willAppear ? offset : phase == .didDisappear ? -offset : 0)
    }
}

/// A page's playback time. The song shown can still be the last one while it slides out (the
/// engine has moved on): its bar holds where it was, and the next song's starts from its own time.
/// Keep one per page (in `@State`).
final class HeldSongTime {
    private var time: TimeInterval = 0

    /// `live`, remembered, while the page's song is the one playing; nil once it isn't, for the
    /// time it was at.
    func show(_ live: TimeInterval?) -> TimeInterval {
        if let live { time = live }
        return time
    }
}
