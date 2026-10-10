import SwiftUI

/// First launch: pick Apple Music or Spotify (or the demo). Spotify gets a second step for the
/// host's own Client ID and sign-in.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var showSpotifySetup = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if showSpotifySetup {
                SpotifySetupStep(back: { withAnimation(.spring(duration: 0.4)) { showSpotifySetup = false } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                chooser
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-onboardingSpotify") { showSpotifySetup = true } }
        #endif
    }

    private var chooser: some View {
        VStack(spacing: 36) {
            LogoView(height: 60)
            VStack(spacing: 10) {
                Text("Where's your music?")
                    .font(.system(size: 40, weight: .bold))
                Text("Pick the service you'll play from. You can switch later in Settings.")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
            }
            GlassEffectContainer(spacing: 28) {
                HStack(spacing: 28) {
                    ServiceCard(
                        icon: Image("AppleMusicIcon"), iconCornerRadius: 0.225,
                        name: "Apple Music",
                        detail: "Plays right on this iPad, to any AirPlay speakers."
                    ) {
                        model.chooseProvider(.appleMusic)
                        Task {
                            await model.requestAuthorization()
                            model.finishOnboarding()
                        }
                    }
                    ServiceCard(
                        icon: Image("SpotifyIcon"), iconCornerRadius: 0.5,
                        name: "Spotify",
                        detail: "Controls Spotify on this iPad or an Apple TV. Needs Premium and a free developer app."
                    ) {
                        model.chooseProvider(.spotify)
                        withAnimation(.spring(duration: 0.4)) { showSpotifySetup = true }
                    }
                }
            }
            Button("Just looking? Try the demo") {
                model.chooseProvider(.demo)
                model.finishOnboarding()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .buttonStyle(.plain)
        }
        .padding(40)
    }
}

private struct ServiceCard: View {
    let icon: Image
    /// Fraction of the icon size: 0.5 for Spotify's circle, ~0.225 for Apple's rounded square.
    let iconCornerRadius: CGFloat
    let name: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                icon
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 88 * iconCornerRadius, style: .continuous))
                Text(name)
                    .font(.system(size: 26, weight: .bold))
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(width: 320, height: 300)
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

private struct SpotifySetupStep: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = SpotifyConfig.clientID
    @State private var working = false
    let back: () -> Void

    private static let readme = URL(string: "https://github.com/narenh/canopy-music#spotify")!

    var body: some View {
        VStack(spacing: 28) {
            Image("SpotifyIcon")
                .resizable()
                .frame(width: 72, height: 72)
            Text("Connect Spotify")
                .font(.system(size: 36, weight: .bold))

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Create an app at developer.spotify.com/dashboard (log in with your Premium account).")
                step(2, "Set the redirect URI to canopy-music://spotify-callback and check Web API.")
                step(3, "Copy the app's Client ID and paste it below.")
                Link("Full instructions on GitHub", destination: Self.readme)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.leading, 36)
            }
            .frame(maxWidth: 560, alignment: .leading)

            TextField("", text: $clientID, prompt: Text("Client ID").foregroundStyle(.white.opacity(0.4)))
                .font(.system(size: 20).monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 22)
                .frame(width: 560, height: 56)
                .glassEffect(.regular.interactive(), in: Capsule())

            HStack(spacing: 16) {
                Button("Back", action: back)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button {
                    working = true
                    model.setSpotifyClientID(clientID)
                    Task {
                        await model.signInToSpotify()
                        working = false
                        if model.spotifyAuth.isSignedIn { model.finishOnboarding() }
                    }
                } label: {
                    if working { ProgressView() } else { Text("Sign in to Spotify").bold() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }

            Button("Do this later") {
                model.setSpotifyClientID(clientID)
                model.finishOnboarding()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .buttonStyle(.plain)
        }
        .padding(40)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.15), in: Circle())
            Text(text)
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
