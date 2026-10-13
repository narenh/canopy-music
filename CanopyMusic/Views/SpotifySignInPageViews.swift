import CanopyMusicCore
import SwiftUI
import UIKit

/// The redirect URI to register in the Spotify app (the sign-in page in use), with Copy.
struct RedirectURIRow: View {
    let uri: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(uri)
                .font(.system(size: 15).monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Button(copied ? "Copied" : "Copy") {
                UIPasteboard.general.string = uri
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .font(.system(size: 14, weight: .semibold))
            .buttonStyle(.glass)
            .tint(.primary)
            .controlSize(.small)
            .accessibilityLabel(copied ? "Copied" : "Copy redirect URI")
        }
    }
}

/// Said plainly when a sign-in is likely to hit Spotify's "Invalid redirect URI" page, which the
/// app can't see: this device last signed in through the old `canopy-music://` address, or the
/// last sign-in's sheet was closed without an answer.
struct SpotifyRedirectNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let uri = model.spotifyRedirectURI
        if model.spotifySignInClosed || model.spotifyAuth.registeredOldRedirect {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(model.spotifySignInClosed
                     ? "Did Spotify say “Invalid redirect URI”? Add \(uri) to your Spotify app's Redirect URIs."
                     : "Canopy Music now signs in to Spotify through a web page. Add \(uri) to your Spotify app's Redirect URIs.")
                    .font(.system(size: 16, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// The "Spotify sign-in page" field: the user's own copy of the relay. Before it's saved, the
/// address is checked (https, loads, has the marker); the result shows under the field. Empty
/// means the default. `isUsable` is false while it's being checked or failed the check.
struct SpotifySignInPageField: View {
    @Environment(AppModel.self) private var model
    @Binding var isUsable: Bool
    var showsHelp = true
    @State private var text = ""
    @State private var result: SpotifyRelay.PageCheck?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $text, prompt: Text("music.canopysf.com/spotify").foregroundStyle(.white.opacity(0.4)))
                .font(.system(size: 17).monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityLabel("Spotify sign-in page")
            status
                .font(.system(size: 14))
                .padding(.horizontal, 8)
        }
        .onAppear { text = model.spotifyOwnSignInPage ?? "" }
        .task(id: text) {
            // Checked once typing pauses.
            let typed = text
            isUsable = false
            checking = true
            result = nil
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let (check, page) = await SpotifyConfig.checkSignInPage(typed)
            guard !Task.isCancelled else { return }
            checking = false
            result = check
            isUsable = check == .ok
            if check == .ok { model.setSpotifySignInPage(page) }
        }
    }

    @ViewBuilder private var status: some View {
        let help = Text(showsHelp ? " Only change this if you host your own copy. Leave it empty to use the default." : "")
            .foregroundStyle(.white.opacity(0.55))
        if checking {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…").foregroundStyle(.orange) }
        } else if let result {
            if result == .ok {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Uses music.canopysf.com.").foregroundStyle(.white.opacity(0.55)) + help
                } else {
                    Text("✓ \(SpotifyConfig.message(for: .ok))").foregroundStyle(.green) + help
                }
            } else {
                Text(SpotifyConfig.message(for: result)).foregroundStyle(Color(red: 1, green: 0.41, blue: 0.38))
            }
        }
    }
}

/// Settings › Spotify › Sign-in page: Default or Your own (which reveals the checked field).
/// Changing it keeps the current sign-in; only new sign-ins use it.
struct SpotifySignInPageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var ownChosen = false
    @State private var usable = true
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Button {
                    ownChosen = false
                    model.setSpotifySignInPage(nil)
                } label: {
                    row("Default", detail: "music.canopysf.com", checked: !ownChosen)
                }
                Button {
                    ownChosen = true
                } label: {
                    row("Your own", detail: model.spotifyOwnSignInPage, checked: ownChosen)
                }
                if ownChosen {
                    SpotifySignInPageField(isUsable: $usable, showsHelp: false)
                        .listRowBackground(Color.clear)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Register the address you use as a Redirect URI in your Spotify app. To host your own copy, see the canopy-music-relay repository.")
                    Button(copied ? "Copied" : "Copy address") {
                        UIPasteboard.general.string = model.spotifyRedirectURI
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                    .font(.footnote.weight(.semibold))
                    .tint(AppModel.Provider.spotify.accent)
                }
            }
            .listRowBackground(Color.white.opacity(0.08))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Sign-in Page")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ownChosen = model.spotifyOwnSignInPage != nil }
    }

    private func row(_ title: String, detail: String?, checked: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if checked {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppModel.Provider.spotify.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
