import CanopyMusicCore
import SwiftUI

/// Ending the zone, with "Save as playlist" (on by default), or saving the party mid-way from
/// Settings. The songs that played, and the requests still waiting, go into the service's account
/// as a playlist named after the party's date plus whatever the host types (docs/multi-device.md).
struct PartyPlaylistSheet: View {
    enum Purpose { case end, save }

    let purpose: Purpose
    /// Runs just before the zone ends, e.g. to close Settings.
    var beforeEnding: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saving = true
    @State private var name = ""
    @State private var onlyRequests = true
    @State private var busy = false
    @State private var errorText: String?
    @State private var savedText: String?
    @FocusState private var nameFocused: Bool

    private var info: PartySaveInfo { model.session.partySaveInfo }
    private var count: Int { onlyRequests ? info.requestCount : info.allCount }
    private var needsSpotifySignIn: Bool { model.provider == .spotify && !model.spotifyAuth.canSavePlaylists }
    /// Whether the main button saves: the switch is on and there's something to save.
    private var willSave: Bool {
        (purpose == .save || saving) && info.destination != nil && count > 0 && !needsSpotifySignIn
    }

    var body: some View {
        NavigationStack {
            Form {
                if purpose == .end {
                    Section {
                        Text("The music stops for everyone and the queue is cleared.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
                if info.destination != nil {
                    playlistSection
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if purpose == .end {
                            Button("End Without Saving", role: .destructive, action: end)
                                .disabled(busy)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
                if let savedText {
                    Section {
                        Label(savedText, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(purpose == .end ? "End \(model.zoneName)?" : "Save as Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if savedText == nil { Button("Cancel") { dismiss() }.disabled(busy) }
                }
                ToolbarItem(placement: .confirmationAction) { primaryButton }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(busy)
        .onAppear {
            name = info.suggestedName
            #if DEBUG
            // `-partyName <name>`: types the rest of the name (the simulator can't be typed into from here).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-partyName"), i + 1 < args.count { name += args[i + 1] }
            #endif
            if info.destination != nil, info.allCount > 0 { nameFocused = true }
        }
        #if DEBUG
        // `-autoEnd` / `-autoSave`: presses the main button 10 s after the sheet opens.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains(purpose == .end ? "-autoEnd" : "-autoSave") else { return }
            try? await Task.sleep(for: .seconds(10))
            await confirm()
        }
        #endif
    }

    @ViewBuilder private var playlistSection: some View {
        Section {
            if purpose == .end {
                Toggle("Save as playlist", isOn: $saving)
            }
            if purpose == .save || saving {
                TextField("Playlist name", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                Toggle("Only songs guests added", isOn: $onlyRequests)
                if needsSpotifySignIn {
                    Button("Sign In to Spotify Again") {
                        Task { await model.signInToSpotify() }
                    }
                }
            }
        } footer: {
            if purpose == .save || saving {
                Text(footer)
            }
        }
        .listRowBackground(Color.white.opacity(0.08))
        .disabled(busy || savedText != nil)
    }

    private var footer: String {
        if needsSpotifySignIn { return "Spotify needs you to sign in again before Canopy Music can save playlists." }
        if count == 0 { return onlyRequests ? "Guests haven't added any songs yet." : "No songs have played or been added yet." }
        return "\(count == 1 ? "1 song" : "\(count) songs"). \(info.destination ?? "")."
    }

    @ViewBuilder private var primaryButton: some View {
        if savedText != nil {
            Button("Done") { dismiss() }
        } else if busy {
            ProgressView()
        } else if purpose == .end {
            Button(!willSave ? "End" : errorText == nil ? "Save and End" : "Try Again") { Task { await confirm() } }
                .tint(.red)
        } else {
            Button(errorText == nil ? "Save" : "Try Again") { Task { await confirm() } }
                .disabled(!willSave)
        }
    }

    private func confirm() async {
        guard willSave else {
            if purpose == .end { end() }
            return
        }
        busy = true
        errorText = nil
        nameFocused = false
        do {
            let saved = try await model.session.savePartyPlaylist(name: name, onlyRequests: onlyRequests)
            busy = false
            if purpose == .end {
                end()
            } else {
                let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = typed.isEmpty ? info.suggestedName.trimmingCharacters(in: .whitespaces) : typed
                savedText = "Saved “\(shown)” with \(saved == 1 ? "1 song" : "\(saved) songs")."
            }
        } catch {
            busy = false
            errorText = "Couldn't save the playlist. \(error.localizedDescription)"
        }
    }

    private func end() {
        dismiss()
        beforeEnding()
        model.endZone()
    }
}
