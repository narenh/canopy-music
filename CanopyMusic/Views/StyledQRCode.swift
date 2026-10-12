import CanopyMusicCore
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision

/// The module grid of a QR code, taken from Core Image's generator so we can draw it our way.
struct QRMatrix {
    let size: Int
    private let modules: [Bool]

    init?(_ payload: String, correction: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage else { return nil }
        // The generator draws one pixel per module plus a quiet-zone border; strip the border.
        let width = Int(output.extent.width), height = Int(output.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(output, toBitmap: &pixels, rowBytes: width * 4, bounds: output.extent,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let dark = { (x: Int, y: Int) in pixels[(y * width + x) * 4] < 128 }
        guard let border = (0..<width).first(where: { i in (0..<height).contains { dark(i, $0) } }) else { return nil }
        let size = width - 2 * border
        self.size = size
        modules = (0..<size * size).map { i in dark(border + i % size, border + i / size) }
    }

    func isDark(_ x: Int, _ y: Int) -> Bool { modules[y * size + x] }

    /// Patterns that must stay exact: timing lines (row and column 6) and the 5×5 alignment
    /// square near the bottom right (present from version 2 up; small codes have just one).
    func inStructure(_ x: Int, _ y: Int) -> Bool {
        if x == 6 || y == 6 { return true }
        guard size >= 25 else { return false }
        let range = (size - 9)...(size - 5)
        return range.contains(x) && range.contains(y)
    }

    /// The three 7×7 corner squares scanners use to find the code.
    func inFinder(_ x: Int, _ y: Int) -> Bool {
        let near = { (v: Int) in v < 7 }, far = { (v: Int) in v >= size - 7 }
        return (near(x) && near(y)) || (far(x) && near(y)) || (near(x) && far(y))
    }
}

/// A QR code drawn module by module: square or round modules, rounded corner squares, and an
/// optional symbol in a cleared center (needs high error correction to stay readable).
struct StyledQRCode: View {
    enum ModuleShape { case square, dot }

    let payload: String
    var shape: ModuleShape = .square
    var symbol: String?
    /// Share of the code's width the cleared center takes.
    var symbolScale: CGFloat = 0.22
    var correction = "H"
    var foreground: Color = .white

    var body: some View {
        if let matrix = QRMatrix(payload, correction: correction) {
            Canvas { context, canvasSize in
                draw(matrix, in: &context, size: canvasSize)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let symbol {
                    GeometryReader { geo in
                        Image(systemName: symbol)
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.semibold)
                            .foregroundStyle(foreground)
                            .frame(width: geo.size.width * symbolScale * 0.62)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
            }
        }
    }

    /// Module rectangle cleared for the symbol, snapped to whole modules and centered.
    private func clearedRange(_ matrix: QRMatrix) -> ClosedRange<Int>? {
        guard symbol != nil else { return nil }
        var span = Int((CGFloat(matrix.size) * symbolScale).rounded())
        if span % 2 != matrix.size % 2 { span += 1 }
        let start = (matrix.size - span) / 2
        return start...(start + span - 1)
    }

    private func draw(_ matrix: QRMatrix, in context: inout GraphicsContext, size: CGSize) {
        let unit = size.width / CGFloat(matrix.size)
        let cleared = clearedRange(matrix)
        var path = Path()
        for y in 0..<matrix.size {
            for x in 0..<matrix.size where matrix.isDark(x, y) && !matrix.inFinder(x, y) {
                if let cleared, cleared.contains(x), cleared.contains(y) { continue }
                let rect = CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: unit, height: unit)
                switch shape {
                case .square: path.addRect(rect.insetBy(dx: -0.25, dy: -0.25))
                case .dot: path.addEllipse(in: rect.insetBy(dx: unit * 0.08, dy: unit * 0.08))
                }
            }
        }
        context.fill(path, with: .color(foreground))

        // Corner squares: a 7-module ring and a 3-module center, rounded for the dot style.
        let radius = shape == .dot ? unit * 2 : 0
        for (fx, fy) in [(0, 0), (matrix.size - 7, 0), (0, matrix.size - 7)] {
            let outer = CGRect(x: CGFloat(fx) * unit, y: CGFloat(fy) * unit, width: unit * 7, height: unit * 7)
            var ring = Path(roundedRect: outer, cornerRadius: radius)
            ring.addPath(Path(roundedRect: outer.insetBy(dx: unit, dy: unit), cornerRadius: max(radius - unit, 0)))
            context.fill(ring, with: .color(foreground), style: FillStyle(eoFill: true))
            context.fill(Path(roundedRect: outer.insetBy(dx: unit * 2, dy: unit * 2), cornerRadius: radius * 0.6),
                         with: .color(foreground))
        }
    }
}

/// A large symbol drawn through the code ("halftone"): the symbol is filled light, and inside it
/// only each module's center carries the code (a dark dot where the code needs a gap). Scanners
/// sample module centers, so the code still reads while the symbol stays big.
struct HalftoneQRCode: View {
    let payload: String
    /// An SF Symbol, or a template image.
    let symbol: Image
    /// Symbol width as a share of the code's width.
    var symbolScale: CGFloat = 0.55
    /// Size of the punched dots inside the symbol, as a share of a module.
    var dotScale: CGFloat = 0.55
    var foreground: Color = .white
    var symbolColor: Color = .white

    init(payload: String, symbol: String, symbolScale: CGFloat = 0.55, dotScale: CGFloat = 0.55,
         foreground: Color = .white, symbolColor: Color = .white) {
        self.init(payload: payload, image: Image(systemName: symbol), symbolScale: symbolScale, dotScale: dotScale,
                  foreground: foreground, symbolColor: symbolColor)
    }

    init(payload: String, image: Image, symbolScale: CGFloat = 0.55, dotScale: CGFloat = 0.55,
         foreground: Color = .white, symbolColor: Color = .white) {
        self.payload = payload
        symbol = image
        self.symbolScale = symbolScale
        self.dotScale = dotScale
        self.foreground = foreground
        self.symbolColor = symbolColor
    }

    var body: some View {
        if let matrix = QRMatrix(payload, correction: "H"), let mask = Self.mask(symbol, modules: matrix.size, scale: symbolScale) {
            Canvas { context, size in
                draw(matrix, mask: mask, in: &context, size: size)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    private func draw(_ matrix: QRMatrix, mask: [Bool], in context: inout GraphicsContext, size: CGSize) {
        let unit = size.width / CGFloat(matrix.size)
        // The symbol, big and centered, fitted the same way as `mask` (aspect fit in a square).
        var image = context.resolve(symbol)
        image.shading = .color(symbolColor)
        let box = size.width * symbolScale
        let fit = min(box / max(image.size.width, 1), box / max(image.size.height, 1))
        let symbolSize = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        context.draw(image, in: CGRect(x: (size.width - symbolSize.width) / 2, y: (size.height - symbolSize.height) / 2,
                                       width: symbolSize.width, height: symbolSize.height))

        var light = Path(), punched = Path()
        for y in 0..<matrix.size {
            for x in 0..<matrix.size where !matrix.inFinder(x, y) {
                let rect = CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: unit, height: unit)
                if mask[y * matrix.size + x], !matrix.inStructure(x, y) {
                    // Inside the light symbol, "on" modules are already light; punch a dark dot
                    // where the code needs a gap.
                    if !matrix.isDark(x, y) {
                        let inset = unit * (1 - dotScale) / 2
                        punched.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
                    }
                } else if matrix.isDark(x, y) {
                    light.addEllipse(in: rect.insetBy(dx: unit * 0.08, dy: unit * 0.08))
                } else if mask[y * matrix.size + x] {
                    // A structural "off" module under the symbol: clear it fully.
                    punched.addRect(rect)
                }
            }
        }
        context.fill(light, with: .color(foreground))
        // Punch real holes so whatever is behind the code (the party background) shows through.
        var holes = context
        holes.blendMode = .destinationOut
        holes.fill(punched, with: .color(.black))

        for (fx, fy) in [(0, 0), (matrix.size - 7, 0), (0, matrix.size - 7)] {
            let outer = CGRect(x: CGFloat(fx) * unit, y: CGFloat(fy) * unit, width: unit * 7, height: unit * 7)
            var ring = Path(roundedRect: outer, cornerRadius: unit * 2)
            ring.addPath(Path(roundedRect: outer.insetBy(dx: unit, dy: unit), cornerRadius: unit))
            context.fill(ring, with: .color(foreground), style: FillStyle(eoFill: true))
            context.fill(Path(roundedRect: outer.insetBy(dx: unit * 2, dy: unit * 2), cornerRadius: unit * 1.2),
                         with: .color(foreground))
        }
    }

    /// Which modules have their center inside the symbol, from a small rendering of it.
    @MainActor static func mask(_ symbol: Image, modules: Int, scale: CGFloat) -> [Bool]? {
        let perModule = 8
        let side = CGFloat(modules * perModule)
        let inner = side * scale
        let view = symbol.resizable().scaledToFit()
            .frame(width: inner, height: inner)
            .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let step = Double(width) / Double(modules)
        return (0..<modules * modules).map { i in
            let px = Int((Double(i % modules) + 0.5) * step), py = Int((Double(i / modules) + 0.5) * step)
            // The bitmap's first row is the top of the image.
            let row = min(py, height - 1)
            return pixels[(row * width + min(px, width - 1)) * 4 + 3] > 127
        }
    }
}

#if DEBUG
/// `-qrGallery`: QR variants side by side, each decoded with Vision to check it still reads.
struct QRGallery: View {
    static let wifi = "WIFI:T:WPA;S:Canopy Guest;P:summer-party-2026;;"

    struct Variant: Identifiable {
        let id = UUID()
        let title: String
        let shape: StyledQRCode.ModuleShape
        let symbol: String?
        let correction: String
        let onLight: Bool
        var symbolScale: CGFloat = 0.22
        var halftone = false
        var tint: Color = .white
        var dotScale: CGFloat = 0.55
    }

    let variants: [Variant] = [
        Variant(title: "Halftone Wi‑Fi 55%", shape: .dot, symbol: "wifi", correction: "H", onLight: false, symbolScale: 0.55, halftone: true),
        Variant(title: "Halftone Wi‑Fi 65%", shape: .dot, symbol: "wifi", correction: "H", onLight: false, symbolScale: 0.65, halftone: true),
        Variant(title: "Halftone, tinted", shape: .dot, symbol: "wifi", correction: "H", onLight: false, symbolScale: 0.6, halftone: true, tint: Color(red: 1, green: 0.78, blue: 0.82)),
        Variant(title: "Halftone, bigger dots", shape: .dot, symbol: "wifi", correction: "H", onLight: false, symbolScale: 0.6, halftone: true, dotScale: 0.7),
        Variant(title: "Dots + Wi‑Fi (H)", shape: .dot, symbol: "wifi", correction: "H", onLight: false),
        Variant(title: "Today (squares, M)", shape: .square, symbol: nil, correction: "M", onLight: false),
    ]

    let oldVariants: [Variant] = [
        Variant(title: "Today (squares, M)", shape: .square, symbol: nil, correction: "M", onLight: false),
        Variant(title: "Squares + Wi‑Fi (H)", shape: .square, symbol: "wifi", correction: "H", onLight: false),
        Variant(title: "Dots (H)", shape: .dot, symbol: nil, correction: "H", onLight: false),
        Variant(title: "Dots + Wi‑Fi (H)", shape: .dot, symbol: "wifi", correction: "H", onLight: false),
        Variant(title: "Dots + Wi‑Fi on light", shape: .dot, symbol: "wifi", correction: "H", onLight: true),
        Variant(title: "Dots + big Wi‑Fi (30%)", shape: .dot, symbol: "wifi", correction: "H", onLight: false, symbolScale: 0.3),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.14, blue: 0.2), Color(red: 0.1, green: 0.07, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: 3), spacing: 28) {
                ForEach(variants) { variant in
                    VStack(spacing: 10) {
                        tile(variant)
                            .frame(width: 220, height: 220)
                        Text(variant.title).font(.headline).foregroundStyle(.white)
                        DecodeBadge(variant: variant)
                    }
                }
            }
            .padding(40)
        }
    }

    @ViewBuilder func tile(_ variant: Variant) -> some View {
        if variant.halftone {
            HalftoneQRCode(payload: Self.wifi, symbol: variant.symbol ?? "wifi", symbolScale: variant.symbolScale,
                           dotScale: variant.dotScale, symbolColor: variant.tint)
                .padding(14)
        } else {
            plainTile(variant)
        }
    }

    @ViewBuilder func plainTile(_ variant: Variant) -> some View {
        let code = StyledQRCode(payload: Self.wifi, shape: variant.shape, symbol: variant.symbol,
                                symbolScale: variant.symbolScale, correction: variant.correction,
                                foreground: variant.onLight ? .black : .white)
        if variant.onLight {
            code.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
        } else {
            code.padding(14)
        }
    }
}

/// Renders the variant as displayed and asks Vision to read it; also tries the colors flipped,
/// since some Android camera apps can't read light-on-dark codes.
private struct DecodeBadge: View {
    let variant: QRGallery.Variant
    @State private var result: String = "Checking…"

    var body: some View {
        Text(result)
            .font(.subheadline.monospaced())
            .foregroundStyle(result.hasPrefix("✓") ? .green : result.hasPrefix("✗") ? .orange : .secondary)
            .task { result = await check() }
    }

    @MainActor private func check() async -> String {
        let background = Color(red: 0.12, green: 0.08, blue: 0.1)
        let shown = QRGallery().tile(variant).frame(width: 440, height: 440)
            .padding(40)
            .background(background)
        let renderer = ImageRenderer(content: shown)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return "✗ render failed" }
        let url = FileManager.default.temporaryDirectory.appending(path: "qr-\(variant.title.filter(\.isLetter)).png")
        try? UIImage(cgImage: image).pngData()?.write(to: url)
        print("[qr] \(variant.title) -> \(url.path)")
        let asShown = Self.decode(image)
        let flipped = Self.decode(Self.inverted(image))
        let ok = { (s: String?) in s == QRGallery.wifi }
        return "\(ok(asShown) ? "✓" : "✗") as shown · \(ok(flipped) ? "✓" : "✗") flipped"
    }

    /// Vision first (what the camera stack resembles); Core Image's detector as a fallback,
    /// since Vision's barcode model may not run in the simulator.
    static func decode(_ image: CGImage?) -> String? {
        guard let image else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            if let value = request.results?.first?.payloadStringValue { return value }
        } catch {
            print("[qr] vision: \(error)")
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let feature = detector?.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature
        return feature?.messageString
    }

    static func inverted(_ image: CGImage) -> CGImage? {
        let filter = CIFilter.colorInvert()
        filter.inputImage = CIImage(cgImage: image)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

#if os(iOS)
/// `-backgroundFor "<search>"`: the party background alone for the first Apple Music match.
struct BackgroundPreview: View {
    let term: String
    @State private var track: QueueTrack?
    @State private var status = "Searching…"

    var body: some View {
        ZStack {
            Color.black
            if let track {
                ThemedBackground(track: track, theme: ArtworkTheme(track.colors))
            } else {
                Text(status).foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .task {
            do {
                let found = try await AppleMusicCatalog(cache: SongCache()).searchSongs(term)
                track = found.first
                print("[background] \(found.first.map { "\($0.title) – \($0.artist) colors=\(String(describing: $0.colors))" } ?? "no match")")
                if found.isEmpty { status = "No match" }
            } catch {
                status = "Search failed: \(error)"
                print("[background] \(error)")
            }
        }
    }
}
#endif
#endif
