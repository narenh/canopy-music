#if DEBUG
import AVFoundation
import SwiftUI

/// Debug builds on a Mac only: is AirPlay from the Mac failing for the app's own audio, or only
/// for the Apple Music player? Shows where the app's audio session says it's playing, and plays
/// three seconds of a tone through the app's own audio (a plain `AVPlayer`) to hear where it goes.
struct AirPlayProbe: View {
    @State private var outputs = AirPlayProbe.currentOutputs()
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AirPlay probe").font(.caption.weight(.semibold))
            Text("Session route: \(outputs)")
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
            Button("Play test tone (3 s)") { playTone() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            Task { @MainActor in refresh(reason: "route change") }
        }
        .task {
            while !Task.isCancelled {
                refresh(reason: nil)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh(reason: String?) {
        let now = Self.currentOutputs()
        if now != outputs || reason != nil {
            print("[airplay-probe] \(reason ?? "poll"): \(now)")
        }
        outputs = now
    }

    private static func currentOutputs() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let names = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private func playTone() {
        guard let url = Self.writeTone() else { return }
        print("[airplay-probe] playing test tone; route: \(Self.currentOutputs())")
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    /// A 3 s, 440 Hz sine as a 16-bit mono WAV in the temporary folder.
    private static func writeTone() -> URL? {
        let rate = 44_100, seconds = 3
        let count = rate * seconds
        var samples = Data(capacity: count * 2)
        for i in 0..<count {
            // Fades in and out over 50 ms so it doesn't click.
            let edge = min(Double(i), Double(count - i)) / (Double(rate) * 0.05)
            let value = sin(2 * .pi * 440 * Double(i) / Double(rate)) * min(edge, 1) * 0.4
            withUnsafeBytes(of: Int16(value * Double(Int16.max)).littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        wav.append(samples)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airplay-probe.wav")
        do { try wav.write(to: url) } catch { return nil }
        return url
    }
}
#endif
