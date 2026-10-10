import SwiftUI

/// First launch: pick Apple Music or Spotify (or the demo). Spotify gets a second step for the
/// host's own Client ID and sign-in.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private enum Step { case chooser, spotify, network }
    @State private var step: Step = .chooser
    /// Where Back on the network step returns to.
    @State private var networkBack: Step = .chooser

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            switch step {
            case .chooser:
                chooser
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .overlay(alignment: .topLeading) {
                        if model.isChangingService {
                            Button("Cancel") { model.cancelChangeService() }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                                .padding(28)
                        }
                    }
            case .spotify:
                SpotifySetupStep(
                    back: { go(.chooser) },
                    done: {
                        model.chooseProvider(.spotify)
                        if model.isChangingService {
                            model.finishOnboarding()
                        } else {
                            networkBack = .spotify
                            go(.network)
                        }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .network:
                NetworkStep(back: { go(networkBack) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-onboardingSpotify") { step = .spotify }
            if ProcessInfo.processInfo.arguments.contains("-onboardingNetwork") { step = .network }
        }
        #endif
    }

    private func go(_ next: Step) {
        withAnimation(.spring(duration: 0.4)) { step = next }
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
                            if model.isChangingService {
                                model.finishOnboarding()
                            } else {
                                networkBack = .chooser
                                go(.network)
                            }
                        }
                    }
                    ServiceCard(
                        icon: Image("SpotifyIcon"), iconCornerRadius: 0.5,
                        name: "Spotify",
                        detail: "Controls Spotify on this iPad or an Apple TV. Needs Premium and a free developer app."
                    ) {
                        // Spotify is only chosen once sign-in succeeds in the next step.
                        go(.spotify)
                    }
                }
            }
            #if DEBUG
            Button("Just looking? Try the demo") {
                model.chooseProvider(.demo)
                model.finishOnboarding()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .buttonStyle(.plain)
            #endif
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

/// Client ID + sign-in. There's no skip: Spotify isn't selectable until this succeeds.
/// Used by onboarding and when switching to Spotify in Settings.
struct SpotifySetupStep: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = SpotifyConfig.clientID
    @State private var working = false
    let back: () -> Void
    let done: () -> Void

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
                step(2, "Set the redirect URI to `canopy-music://spotify-callback` and check the `Web API` box.")
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
                        if model.spotifyAuth.isSignedIn { done() }
                    }
                } label: {
                    if working { ProgressView() } else { Text("Sign in to Spotify").bold() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(40)
    }

    /// `text` is Markdown, so `code` spans render monospaced.
    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
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

/// Explains phone queueing before iPadOS asks for local network access. Continue finishes setup,
/// which starts the phone page and triggers the system prompt; Not now turns queueing off.
private struct NetworkStep: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "network")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text("Let guests queue from their phones")
                .font(.system(size: 36, weight: .bold))
            Text("Canopy Music runs a small local web server so guests on your Wi\u{2011}Fi can queue songs. They don't need an app or a music subscription.")
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            HStack(spacing: 16) {
                Button("Back", action: back)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button {
                    model.phoneQueueEnabled = true
                    model.finishOnboarding()
                } label: {
                    Text("Continue").bold()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }

            Button("Not now") {
                model.phoneQueueEnabled = false
                model.finishOnboarding()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .buttonStyle(.plain)

            Text("You can change this anytime in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(40)
    }
}
