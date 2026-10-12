import CanopyCore
import CanopyServer
import SwiftUI

/// Every launch starts here: the zones on this Wi‑Fi, plus "Create a new zone" (docs/multi-device.md).
struct ZoneListView: View {
    @Environment(AppModel.self) private var model
    /// The list's content height, so it's only as tall as its rows and the whole screen can be
    /// centered (a List otherwise takes all the height it's offered).
    @State private var listHeight: CGFloat = 300

    var body: some View {
        let zones = model.zoneBrowser.zones.filter { $0.hubID != model.deviceID }
        ZStack {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                LogoView(height: 44)
                    .padding(.bottom, 28)
                List {
                    // Hidden until there's a zone to show. This iPad's own zone from last time
                    // comes first.
                    if !zones.isEmpty || model.canResumeZone {
                        Section("Active Zones") {
                            if model.canResumeZone {
                                ZoneRow(icon: "ipad.landscape", title: model.zoneName, subtitle: "Resume on this iPad") {
                                    model.resumeZone()
                                }
                            }
                            zoneRows(zones)
                        }
                    }
                    Section {
                        ZoneRow(icon: "plus", title: "Create a new zone", subtitle: "Music plays from this iPad") {
                            model.beginCreatingZone()
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                } action: { _, height in
                    // Before the rows are laid out it reports nothing; collapsing then would stick.
                    if height > 1 { listHeight = height }
                }
                .frame(maxWidth: 560, maxHeight: listHeight)
                Spacer(minLength: 24)
                // A little more room below than above, so it looks centered rather than sitting low.
                Color.clear.frame(height: 64)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: zones.map(\.id))
        .onAppear { model.zoneBrowser.start() }
        #if DEBUG
        // `-joinZone <name>`: joins that zone as soon as it shows up (testing displays in the simulator).
        .onChange(of: zones.map(\.id), initial: true) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-joinZone"), i + 1 < args.count,
                  let zone = zones.first(where: { $0.name == args[i + 1] }) else { return }
            model.join(zone)
        }
        #endif
    }

    private func zoneRows(_ zones: [ZoneListing]) -> some View {
        ForEach(zones) { zone in
            ZoneRow(
                icon: zone.kind == .tv ? "appletv" : "ipad.landscape",
                title: zone.name,
                subtitle: [zone.kind == .tv ? "Apple TV" : "iPad", zone.nowPlaying.map { "Playing \($0)" }]
                    .compactMap(\.self).joined(separator: " · ")
            ) {
                model.join(zone)
            }
        }
    }
}

private struct ZoneRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .medium))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .listRowBackground(Color.white.opacity(0.08))
    }
}

/// Creating a zone on this iPad: a name (defaults to the device name), then an optional host PIN.
struct CreateZoneView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var name = UIDevice.current.name
    @State private var pin = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                LogoView(height: 40)
                if step == 0 {
                    nameStep
                } else {
                    pinStep
                }
            }
            .padding(40)
            .foregroundStyle(.white)
            .frame(maxWidth: 560)
        }
        .overlay(alignment: .topLeading) {
            Button(step == 0 ? "Cancel" : "Back") {
                if step == 0 { model.cancelCreatingZone() } else { withAnimation { step = 0 } }
            }
            .buttonStyle(.glass)
            .tint(.primary)
            .padding(24)
        }
    }

    private var nameStep: some View {
        VStack(spacing: 18) {
            Text("Name this zone").font(.system(size: 34, weight: .bold))
            Text("Shown to other Canopy Music devices on the Wi\u{2011}Fi.")
                .foregroundStyle(.white.opacity(0.6))
            TextField("Zone name", text: $name)
                .font(.system(size: 20))
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($nameFocused)
                .submitLabel(.continue)
                .onSubmit(next)
            Button("Continue", action: next)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { nameFocused = true }
    }

    private var pinStep: some View {
        VStack(spacing: 18) {
            Text("Set a host PIN").font(.system(size: 34, weight: .bold))
            Text("Optional PIN for accessing host settings.")
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color.white : Color.white.opacity(0.2))
                        .frame(width: 14, height: 14)
                }
            }
            PINPad(pin: $pin, length: 4) { done in
                model.finishCreatingZone(name: name, pin: done)
            }
            Button("Skip") { model.finishCreatingZone(name: name, pin: nil) }
                .buttonStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func next() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        nameFocused = false
        withAnimation { step = 1 }
    }
}

/// Number pad that calls `onComplete` once `length` digits are in.
struct PINPad: View {
    @Binding var pin: String
    let length: Int
    let onComplete: (String) -> Void

    var body: some View {
        GlassEffectContainer {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 16), count: 3), spacing: 16) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"], id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(height: 78)
                    } else {
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(.system(size: 28, weight: .medium))
                                .frame(width: 78, height: 78)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func press(_ key: String) {
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard pin.count < length else { return }
        pin.append(key)
        if pin.count == length { onComplete(pin) }
    }
}
