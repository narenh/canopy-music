@testable import CanopyMusicCore
import Testing

/// The party screen's speaker button: Speakers on Sonos, AirPlay while the music plays from this
/// device (dimmed where it doesn't apply), nothing on a display.
@Suite struct PartySpeakerButtonTests {
    func button(display: Bool = false, sonos: Bool = false, spotify: Bool = false, spotifyHere: Bool = true,
                mac: Bool = false) -> PartySpeakerButton {
        PartySpeakerButton.choose(isDisplay: display, onSonos: sonos, isSpotify: spotify, spotifyPlaysHere: spotifyHere, isMac: mac)
    }

    /// Apple Music on this device: always AirPlay, Sonos rooms around or not.
    @Test func appleMusicHereIsAirPlay() {
        #expect(button() == .airPlay)
        // A Mac's music ignores the app's AirPlay choice.
        #expect(button(mac: true) == .airPlayUnavailable)
    }

    @Test func spotifyIsAirPlayOnlyWhenItPlaysHere() {
        #expect(button(spotify: true) == .airPlay)
        #expect(button(spotify: true, spotifyHere: false) == .airPlayUnavailable)
        #expect(button(spotify: true, mac: true) == .airPlayUnavailable)
    }

    /// On Sonos it's the Speakers panel, whichever service and device.
    @Test func onSonosItsSpeakers() {
        #expect(button(sonos: true) == .sonosSpeakers)
        #expect(button(sonos: true, spotify: true, spotifyHere: false) == .sonosSpeakers)
        #expect(button(sonos: true, mac: true) == .sonosSpeakers)
    }

    @Test func displaysHaveNone() {
        #expect(button(display: true) == .none)
        #expect(button(display: true, sonos: true) == .none)
    }
}
