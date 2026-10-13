import AuthenticationServices
import CanopyMusicCore
import UIKit

/// The iPad (and Mac) sign-in: Spotify's page in an in-app browser sheet. Spotify sends the
/// browser to the sign-in page (the relay), whose `location.replace` to
/// `canopy-music://spotify-callback?…` ends the sheet with the answer.
extension SpotifyAuth {
    func signIn() async throws {
        let request = try newRequest(destination: .app)
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: request.authorizeURL, callbackURLScheme: SpotifyConfig.callbackScheme) { url, _ in
                // No URL: the sheet was closed (or failed) before the relay sent anything back.
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: SpotifyError.signInClosed) }
            }
            session.presentationContextProvider = PresentationAnchor.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
        switch request.callback(SpotifySignInRequest.query(of: callback)) {
        case .code(let code):
            try await complete(request, code: code)
        case .cancelled:
            throw SpotifyError.signInCancelled
        case .failed(let reason):
            throw SpotifyError.signInFailed(reason)
        case .notOurs:
            // Another sign-in's answer (an old link, say): not used.
            throw SpotifyError.signInFailed("the answer wasn't for this sign-in; try again")
        }
    }
}

private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    @MainActor static let shared = PresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.compactMap(\.keyWindow).first ?? scenes.first?.windows.first { return window }
            return ASPresentationAnchor(windowScene: scenes.first!)
        }
    }
}
