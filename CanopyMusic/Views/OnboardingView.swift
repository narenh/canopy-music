import SwiftUI

/// Setup's first step, the first time "Create a new zone" is pressed: pick Apple Music or Spotify
/// (or the demo); each card says where its service stands. Spotify, if it isn't signed in, pushes
/// its setup page (the host's own developer app, Client ID and sign-in), then asks where music
/// plays. Then the phone-queueing step, and setup's second step, the zone's name and
/// PIN (`CreateZoneView`). It never comes back once a service is chosen.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private enum Step { case chooser, spotify, network }
    @State private var step: Step = .chooser
    /// Where Back on the network step returns to.
    @State private var networkBack: Step = .chooser

    var body: some View {
        ZStack {
            DuskBackground()
            ContentCap {
                switch step {
                case .chooser:
                    chooser
                        .transition(.move(edge: .leading).combined(with: .opacity))
                case .spotify:
                    SpotifySetupStep(
                        back: { go(.chooser) },
                        done: {
                            model.chooseProvider(.spotify)
                            model.isPickingSpotifyDevice = true
                            networkBack = .spotify
                            go(.network)
                        }
                    )
                    // Spotify green regardless of the current service (a fresh install defaults to Apple Music).
                    .tint(AppModel.Provider.spotify.accent)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                case .network:
                    NetworkStep(back: { go(networkBack) })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        // After signing in to Spotify: "Where should music play?"
        .outputPicker(includesSonos: false)
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
                Text("Pick the service you'll play from. You can switch later, before you press Start.")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
            }
            GlassEffectContainer(spacing: 28) {
                HStack(spacing: 28) {
                    ServiceCard(
                        icon: Image("AppleMusicIcon"), iconCornerRadius: 0.225,
                        name: "Apple Music",
                        detail: "Plays right on this \(DeviceKind.noun), to any AirPlay speakers.",
                        status: model.serviceDetail(.appleMusic)
                    ) {
                        model.chooseProvider(.appleMusic)
                        Task {
                            await model.requestAuthorization()
                            networkBack = .chooser
                            go(.network)
                        }
                    }
                    ServiceCard(
                        icon: Image("SpotifyIcon"), iconCornerRadius: 0.5,
                        name: "Spotify",
                        detail: "Controls Spotify on this \(DeviceKind.noun) or an Apple TV. Needs Premium and a free developer app.",
                        status: model.serviceDetail(.spotify)
                    ) {
                        // Already signed in (e.g. a reinstall kept the sign-in): no need to sign in again.
                        if model.spotifyAuth.isSignedIn, !model.spotifyClientID.isEmpty {
                            model.chooseProvider(.spotify)
                            model.isPickingSpotifyDevice = true
                            networkBack = .chooser
                            go(.network)
                        } else {
                            // Spotify is only chosen once sign-in succeeds in the next step.
                            go(.spotify)
                        }
                    }
                }
            }
            #if DEBUG
            if !Capture.isOn {
            Button("Just looking? Try the demo") {
                model.chooseProvider(.demo)
                model.finishOnboarding()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .buttonStyle(.plain)
            }
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
    /// The service's state (`AppModel.serviceDetail`), under the name, as the start screen's
    /// service menu says it.
    let status: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                icon
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 88 * iconCornerRadius, style: .continuous))
                VStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 26, weight: .bold))
                    if let status {
                        Text(status)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(width: 320, height: 320)
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

/// Spotify's setup page: how to create the Spotify developer app, its Client ID, and the
/// sign-in, with Advanced (the sign-in page) for people hosting their own relay. A page of its
/// own, scrolling, so nothing is cramped. There's no skip: Spotify isn't chosen until the sign-in
/// succeeds (`done`); Back (`back`) leaves the service as it was. Pushed by setup's service step,
/// and shown full screen from the start screen's Music row.
struct SpotifySetupStep: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = SpotifyConfig.clientID
    @State private var working = false
    /// Advanced: the user's own sign-in page. Open from the start if one is set.
    @State private var showsAdvanced = SpotifyConfig.ownSignInPage != nil
    @State private var signInPageUsable = true
    let back: () -> Void
    let done: () -> Void

    init(back: @escaping () -> Void, done: @escaping () -> Void) {
        self.back = back
        self.done = done
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .tint(.primary)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Back")
                    Spacer()
                    Image("SpotifyIcon")
                        .resizable()
                        .frame(width: 44, height: 44)
                }
                .padding(.bottom, 22)

                Text("Connect Spotify")
                    .font(.system(size: 36, weight: .bold))
                Text("Canopy Music plays Spotify through a developer app you create. It's free, and you only do this once.")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 28)

                steps
                    .padding(.bottom, 30)

                Text("Client ID")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 20)
                    .padding(.bottom, 8)
                TextField("", text: $clientID, prompt: Text("Client ID").foregroundStyle(.white.opacity(0.4)))
                    .font(.system(size: 20).monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 22)
                    .frame(height: 56)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .accessibilityLabel("Client ID")

                SpotifyRedirectNotice()
                    .padding(.top, 16)

                Button {
                    working = true
                    model.setSpotifyClientID(clientID)
                    Task {
                        await model.signInToSpotify()
                        working = false
                        if model.spotifyAuth.isSignedIn { done() }
                    }
                } label: {
                    ZStack {
                        Text("Sign in to Spotify").bold().opacity(working ? 0 : 1)
                        if working { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                // Sign-in stays off until the sign-in page is good (or the default).
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || working || (showsAdvanced && !signInPageUsable))
                .padding(.top, 16)

                Text("Your family can share one app if each person's email is added under User Management in the app's settings.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)

                Divider()
                    .overlay(.white.opacity(0.15))
                    .padding(.top, 34)
                advanced
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        #if DEBUG
        // `-spotifyAdvanced`: opens Advanced (the simulator can't be tapped from here).
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-spotifyAdvanced") { showsAdvanced = true } }
        #endif
    }

    /// Creating the Spotify app, step by step. Markdown: `**` bold, `[…](…)` links.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(1, "Go to [**developer.spotify.com/dashboard**](https://developer.spotify.com/dashboard) and log in with your Spotify account. Playback needs Spotify Premium.")
            step(2, "If Spotify asks, accept the Developer Terms.")
            step(3, "Tap **Create app**.")
            step(4, "Give it any name and description, like “Canopy Music”.")
            step(5, "Under **Redirect URIs**, paste") {
                RedirectURIRow(uri: model.spotifyRedirectURI)
                Text("and tap **Add**.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.8))
            }
            step(6, "Under **Which API/SDKs are you planning to use?**, check **Web API**.")
            step(7, "Agree to the terms and tap **Save**.")
            step(8, "On your new app's page, open **Settings** and copy the **Client ID**.")
            step(9, "Paste it below.")
        }
    }

    /// Quiet, and collapsed: only for people who host their own copy of the sign-in relay.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showsAdvanced.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("Advanced")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    Text("Only for people who host their own copy of the Canopy Music sign-in relay. Most people can ignore this.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsAdvanced ? "Shown" : "Hidden")

            if showsAdvanced {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spotify sign-in page")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.leading, 20)
                    SpotifySignInPageField(isUsable: $signInPageUsable)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        step(number, text) { EmptyView() }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey, @ViewBuilder below: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                below()
            }
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
                    .tint(.primary)
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
