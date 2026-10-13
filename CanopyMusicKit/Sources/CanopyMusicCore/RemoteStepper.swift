import Foundation

/// The Apple TV remote's left and right on the party screen: `previous()` and `skip()`, the same
/// as the back and skip buttons elsewhere, but one at a time. While one is still going (until the
/// session, or a display's hub, has moved on), further presses are ignored rather than queued.
@MainActor
public final class RemoteStepper {
    /// A step that hasn't finished yet.
    public private(set) var isStepping = false

    public init() {}

    /// Left (`forward: false`) or right. A hub always steps; a display only while its hub lets
    /// displays control playback, through the same commands its other controls send. Returns
    /// whether this press went.
    @discardableResult
    public func step(_ session: PartySession, forward: Bool) async -> Bool {
        guard !isStepping, session.remote == nil || session.displaysCanControl else { return false }
        isStepping = true
        defer { isStepping = false }
        if forward { await session.skip() } else { await session.previous() }
        return true
    }
}
