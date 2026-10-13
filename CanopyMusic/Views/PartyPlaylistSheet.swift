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
    @State private var name = ""
    @State private var onlyRequests = true
    @State private var busy = false
    @State private var errorText: String?
    @State private var savedText: String?
    @FocusState private var nameFocused: Bool

    private var info: PartySaveInfo { model.session.partySaveInfo }
    private var count: Int { onlyRequests ? info.requestCount : info.allCount }
    private var needsSpotifySignIn: Bool { model.provider == .spotify && !model.spotifyAuth.canSavePlaylists }
    /// Whether saving is possible: somewhere to save, something to save, and signed in.
    private var willSave: Bool {
        info.destination != nil && count > 0 && !needsSpotifySignIn
    }

    /// The name the playlist will actually get: what's typed, or the suggested name.
    private var finalName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? info.suggestedName.trimmingCharacters(in: .whitespaces) : typed
    }

    var body: some View {
        NavigationStack {
            Form {
                if purpose == .end {
                    // The most important thing on the sheet, so it reads as text, not a list row.
                    Section {
                        Text("The music stops for everyone and the queue is cleared.")
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                if info.destination != nil {
                    playlistSection
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
                if purpose == .end && savedText == nil {
                    endButtons
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
                // Ending has its two buttons under the form; saving from Settings keeps the bar's.
                if purpose == .save || savedText != nil {
                    ToolbarItem(placement: .confirmationAction) { primaryButton }
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(busy)
        .defaultFocus($nameFocused, info.destination != nil && info.allCount > 0)
        .onAppear {
            name = info.suggestedName
            #if DEBUG
            // `-partyName <name>`: types the rest of the name (the simulator can't be typed into from here).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-partyName"), i + 1 < args.count { name += args[i + 1] }
            #endif
        }
        // The name field starts focused. Set again once the sheet has finished appearing: focus
        // set while it's still animating in can be dropped.
        .task {
            guard info.destination != nil, info.allCount > 0 else { return }
            nameFocused = true
            try? await Task.sleep(for: .milliseconds(400))
            if !busy { nameFocused = true }
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
            TextField("Playlist name", text: $name)
                .focused($nameFocused)
                .submitLabel(.done)
            Toggle("Only songs guests added", isOn: $onlyRequests)
            if needsSpotifySignIn {
                Button("Sign In to Spotify Again") {
                    Task { await model.signInToSpotify() }
                }
            }
        } footer: {
            footer
        }
        .listRowBackground(Color.white.opacity(0.08))
        .disabled(busy || savedText != nil)
    }

    /// "3 songs. Saves to your Apple Music library as **2026-10-12 Bedroom**."
    @ViewBuilder private var footer: some View {
        if needsSpotifySignIn {
            Text("Spotify needs you to sign in again before Canopy Music can save playlists.")
        } else if count == 0 {
            Text(onlyRequests ? "Guests haven't added any songs yet." : "No songs have played or been added yet.")
        } else {
            Text("\(count == 1 ? "1 song" : "\(count) songs"). \(info.destination ?? "") as \(Text(finalName).fontWeight(.semibold)).")
        }
    }

    /// Ending: End without Saving beside Save and End, under the playlist's details.
    private var endButtons: some View {
        Section {
            HStack(spacing: 12) {
                Button(role: .destructive, action: end) {
                    Text("End without Saving")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                Button {
                    Task { await confirm() }
                } label: {
                    Group {
                        if busy { ProgressView() } else { Text(errorText == nil ? "Save and End" : "Try Again").bold() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!willSave)
            }
            .controlSize(.large)
            .disabled(busy)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var primaryButton: some View {
        if savedText != nil {
            Button("Done") { dismiss() }
        } else if busy {
            ProgressView()
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
                savedText = "Saved “\(finalName)” with \(saved == 1 ? "1 song" : "\(saved) songs")."
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
