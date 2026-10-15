/// The party screen's speaker button, left of the transport controls (iPad and Mac): how the
/// zone's music gets to its speakers, and where it can move. Spotify's own device button sits on
/// the other side (where crossfade is for Apple Music) and lists its Spotify Connect devices;
/// this side stays AirPlay for Spotify, as it was.
public enum PartySpeakerButton: Equatable, Sendable {
    /// A display: speakers are chosen on the hub. A space keeps the controls centred.
    case none
    /// The music plays on Sonos rooms: Speakers, their panel.
    case sonosSpeakers
    /// "Where should music play?": Apple Music on this device with Sonos rooms on the Wi‑Fi, so
    /// the music can move to them without leaving the party screen. AirPlay is a tap further, on
    /// the picker's This iPad row.
    case outputPicker
    /// The system AirPlay picker (AirPlay sessions sometimes drop and need re-picking).
    case airPlay
    /// AirPlay, dimmed (kept for balance): Spotify plays on another device, or this is a Mac,
    /// where the music ignores the app's AirPlay choice.
    case airPlayUnavailable

    /// `sonosRoomsFound`: the zone's service can play on Sonos and the household has rooms.
    public static func choose(isDisplay: Bool, onSonos: Bool, isSpotify: Bool, spotifyPlaysHere: Bool, isMac: Bool,
                              sonosRoomsFound: Bool) -> PartySpeakerButton {
        if isDisplay { return .none }
        if onSonos { return .sonosSpeakers }
        // Apple Music only: Spotify's device button is its picker.
        if !isSpotify, sonosRoomsFound { return .outputPicker }
        if isMac || (isSpotify && !spotifyPlaysHere) { return .airPlayUnavailable }
        return .airPlay
    }
}
