/// The party screen's speaker button, left of the transport controls (iPad and Mac): AirPlay
/// while the music plays from this device (one tap reaches every AirPlay speaker's volume), or
/// Speakers while it plays on Sonos rooms. Moving the music between the two is the start
/// screen's. Spotify's device button sits on the other side (where crossfade is for Apple Music).
public enum PartySpeakerButton: Equatable, Sendable {
    /// A display: speakers are chosen on the hub. A space keeps the controls centred.
    case none
    /// The music plays on Sonos rooms: Speakers, their panel.
    case sonosSpeakers
    /// The system AirPlay picker (AirPlay sessions sometimes drop and need re-picking).
    case airPlay
    /// AirPlay, dimmed (kept for balance): Spotify plays on another device, or this is a Mac,
    /// where the music ignores the app's AirPlay choice.
    case airPlayUnavailable

    public static func choose(isDisplay: Bool, onSonos: Bool, isSpotify: Bool, spotifyPlaysHere: Bool, isMac: Bool) -> PartySpeakerButton {
        if isDisplay { return .none }
        if onSonos { return .sonosSpeakers }
        if isMac || (isSpotify && !spotifyPlaysHere) { return .airPlayUnavailable }
        return .airPlay
    }
}
