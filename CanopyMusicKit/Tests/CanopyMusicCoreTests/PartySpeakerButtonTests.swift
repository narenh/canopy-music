@testable import CanopyMusicCore
import Testing

/// The party screen's speaker button: Speakers on Sonos, "Where should music play?" for Apple
/// Music on this device while Sonos rooms are around, AirPlay otherwise.
@Suite struct PartySpeakerButtonTests {
    func button(display: Bool = false, sonos: Bool = false, spotify: Bool = false, spotifyHere: Bool = true, mac: Bool = false,
                rooms: Bool = false) -> PartySpeakerButton {
        PartySpeakerButton.choose(isDisplay: display, onSonos: sonos, isSpotify: spotify, spotifyPlaysHere: spotifyHere, isMac: mac,
                                  sonosRoomsFound: rooms)
    }

    /// Apple Music on this device: the picker once there are rooms to move to, AirPlay until then.
    @Test func appleMusicOffersThePickerWithRooms() {
        #expect(button(rooms: true) == .outputPicker)
        #expect(button(rooms: false) == .airPlay)
        // On a Mac too, where AirPlay doesn't apply at all.
        #expect(button(mac: true, rooms: true) == .outputPicker)
        #expect(button(mac: true, rooms: false) == .airPlayUnavailable)
    }

    /// Spotify zones are left as they were: its device button is its picker, so this side stays AirPlay.
    @Test func spotifyKeepsAirPlay() {
        #expect(button(spotify: true, rooms: true) == .airPlay)
        #expect(button(spotify: true, spotifyHere: false, rooms: true) == .airPlayUnavailable)
        #expect(button(spotify: true, mac: true, rooms: true) == .airPlayUnavailable)
    }

    /// Once the music is on Sonos (moved from the party screen or not), it's the Speakers panel.
    @Test func onSonosItsSpeakers() {
        #expect(button(sonos: true, rooms: true) == .sonosSpeakers)
        #expect(button(sonos: true, spotify: true, spotifyHere: false, rooms: true) == .sonosSpeakers)
        #expect(button(sonos: true, mac: true) == .sonosSpeakers)
    }

    @Test func displaysHaveNone() {
        #expect(button(display: true, rooms: true) == .none)
        #expect(button(display: true, sonos: true) == .none)
    }
}
