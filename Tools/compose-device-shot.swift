// Composes an iPad (landscape) and iPhone screenshot in drawn device frames on a background.
// Usage: swift Tools/compose-device-shot.swift background.png ipad.png iphone.png out.png
// Env: SQUARE=<side> for a square canvas, LOGO=<png> centered above (ICON=<png> beside it, LOGO_SCALE=<share of width>),
//      DOCK=<png> app icon centered on the iPad's bottom edge (DOCK_POS=over|below, DOCK_SCALE=<share of iPad width>,
//      DOCK_BG=0 for the icon alone without the glass tile), OVERLAP=<0..1> phone over the iPad, NO_ISLAND=1 for simulator phone shots.
//      TV=<png> a flat-panel TV behind the iPad and iPhone, which stand in front of its lower part:
//        TV_WIDTH=<share of width> (0.8), TV_COVER=<share of the TV's height behind the iPad> (0.4), TV_X=<shift, share of width>,
//        TV_STAND=1 for a pedestal stand, DEVICES=<scale of the iPad + iPhone pair> (0.8 with a TV), DEVICES_X=<shift, share of width>.
//      LAYERS_DIR=<dir> also writes each element as a cropped transparent PNG plus layers.svg (the PNGs embedded,
//        positioned as in out.png) for rearranging in Figma; out.png is then flattened from those same layers.
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
func load(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
let background = load(args[1]), ipadShot = load(args[2]), phoneShot = load(args[3])
let env = ProcessInfo.processInfo.environment
func number(_ key: String) -> CGFloat? { env[key].flatMap(Double.init).map { CGFloat($0) } }
let square = env["SQUARE"].flatMap(Int.init)
let W = square ?? background.width, H = square ?? background.height
func makeCanvas() -> CGContext {
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    // Work top-down like a screen.
    c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)
    return c
}
let canvas = makeCanvas()
/// Where drawing goes: the canvas, or the layer being drawn on its own (`LAYERS_DIR`).
var ctx = canvas

func drawImage(_ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

// MARK: Layers

let layersDir = env["LAYERS_DIR"]
struct Layer { let name: String; let image: CGImage; let frame: CGRect }
var layers: [Layer] = []

/// The smallest rect holding every pixel that isn't fully transparent (top-down canvas pixels).
func opaqueBounds(_ c: CGContext) -> CGRect? {
    let bytes = c.data!.assumingMemoryBound(to: UInt8.self), rowBytes = c.bytesPerRow
    var minX = W, maxX = -1, minY = H, maxY = -1
    for y in 0..<H {
        let row = bytes + y * rowBytes
        // Alpha is the first byte of each pixel.
        var first = -1
        for x in 0..<W where row[x * 4] != 0 { first = x; break }
        guard first >= 0 else { continue }
        var last = first
        for x in stride(from: W - 1, through: first, by: -1) where row[x * 4] != 0 { last = x; break }
        minX = min(minX, first); maxX = max(maxX, last); minY = min(minY, y); maxY = y
    }
    return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Draws one element: straight onto the canvas, or with `LAYERS_DIR` on its own transparent
/// canvas that's kept (cropped) as a layer and then composited.
func layer(_ name: String, _ draw: () -> Void) {
    guard layersDir != nil else { draw(); return }
    let own = makeCanvas()
    ctx = own
    draw()
    ctx = canvas
    guard let frame = opaqueBounds(own), let full = own.makeImage(), let cropped = full.cropping(to: frame) else { return }
    layers.append(Layer(name: name, image: cropped, frame: frame))
    drawImage(cropped, in: frame)
}

// MARK: Devices

/// A device: aluminum rim, black bezel, rounded screen with the screenshot.
func device(screen: CGRect, image: CGImage, bezel: CGFloat, screenRadius: CGFloat, rim: CGFloat, island: CGSize? = nil) {
    let outer = screen.insetBy(dx: -(bezel + rim), dy: -(bezel + rim))
    let outerRadius = screenRadius + bezel + rim
    // Shadow under the whole device.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -bezel * 0.6), blur: bezel * 3.5, color: CGColor(gray: 0, alpha: 0.55))
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.62, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // Rim: a light-to-dark gradient reads as brushed metal.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
    ctx.clip()
    let metal = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(gray: 0.78, alpha: 1), CGColor(gray: 0.42, alpha: 1), CGColor(gray: 0.66, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: outer.minX, y: outer.minY), end: CGPoint(x: outer.maxX, y: outer.maxY), options: [])
    ctx.restoreGState()
    // Bezel.
    let glass = outer.insetBy(dx: rim, dy: rim)
    ctx.addPath(CGPath(roundedRect: glass, cornerWidth: outerRadius - rim, cornerHeight: outerRadius - rim, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
    ctx.fillPath()
    // Screen.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
    ctx.clip()
    drawImage(image, in: screen)
    ctx.restoreGState()
    if let island {
        let rect = CGRect(x: screen.midX - island.width / 2, y: screen.minY + island.height * 0.32, width: island.width, height: island.height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
    }
}

/// A flat-panel TV: thin black bezel, a slim graphite edge, nearly square corners, and an
/// optional pedestal stand.
let tvBezelShare: CGFloat = 0.0085, tvEdgeShare: CGFloat = 0.0016
func television(screen: CGRect, image: CGImage, stand: Bool) {
    let bezel = screen.width * tvBezelShare, edge = screen.width * tvEdgeShare
    let outer = screen.insetBy(dx: -(bezel + edge), dy: -(bezel + edge))
    let radius = edge + bezel * 0.3
    let graphite = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(gray: 0.34, alpha: 1), CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.22, alpha: 1),
    ] as CFArray, locations: [0, 0.5, 1])!
    if stand {
        // A neck from behind the panel down to a low, wide foot.
        let neck = CGRect(x: outer.midX - outer.width * 0.035, y: outer.maxY - outer.height * 0.1,
                          width: outer.width * 0.07, height: outer.height * 0.1 + outer.width * 0.04)
        let foot = CGRect(x: outer.midX - outer.width * 0.16, y: neck.maxY - outer.width * 0.004,
                          width: outer.width * 0.32, height: outer.width * 0.012)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -foot.height * 0.6), blur: foot.height * 2.2, color: CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(CGPath(roundedRect: foot, cornerWidth: foot.height / 2, cornerHeight: foot.height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        for part in [neck, foot] {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: part, cornerWidth: min(part.height, part.width) * 0.2, cornerHeight: min(part.height, part.width) * 0.2, transform: nil))
            ctx.clip()
            ctx.drawLinearGradient(graphite, start: CGPoint(x: part.minX, y: part.minY), end: CGPoint(x: part.maxX, y: part.minY), options: [])
            ctx.restoreGState()
        }
    }
    // A soft shadow behind the panel, as if it stands a little in front of the backdrop.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -outer.height * 0.015), blur: outer.width * 0.035, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    // The edge, catching a little light at the top.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(graphite, start: CGPoint(x: outer.minX, y: outer.minY), end: CGPoint(x: outer.minX, y: outer.maxY), options: [])
    ctx.restoreGState()
    // Bezel.
    let front = outer.insetBy(dx: edge, dy: edge)
    ctx.addPath(CGPath(roundedRect: front, cornerWidth: radius - edge, cornerHeight: radius - edge, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.02, alpha: 1)); ctx.fillPath()
    // Screen, with a faint sheen across the glass.
    drawImage(image, in: screen)
    ctx.saveGState()
    ctx.clip(to: screen)
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(gray: 1, alpha: 0.05), CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.midX, y: screen.maxY), options: [])
    ctx.restoreGState()
}

// MARK: Layout

// Real proportions: iPad Pro 11" (M4) is ~249.7 × 177.5 mm (screen ~236 mm wide), iPhone 17 Pro ~150 × 71.9 mm.
let ipadAspect = CGFloat(ipadShot.height) / CGFloat(ipadShot.width)
let phoneAspect = CGFloat(phoneShot.width) / CGFloat(phoneShot.height)
let margin = CGFloat(W) * 0.05, gap = CGFloat(W) * 0.025
let tvShot = env["TV"].map(load)
// Optional overlap: the phone stands in front of the iPad's right edge (fraction of the phone's width).
let overlap = CGFloat(env["OVERLAP"].flatMap(Double.init) ?? 0)
var logo: CGImage?, logoW: CGFloat = 0, logoH: CGFloat = 0
if let logoPath = env["LOGO"] {
    logo = load(logoPath)
    logoW = CGFloat(W) * (number("LOGO_SCALE") ?? 0.32)
    logoH = logoW * CGFloat(logo!.height) / CGFloat(logo!.width)
}
// Widest iPad screen such that iPad + gap + phone (minus overlap) fill the width between margins
// (scaled down by DEVICES, which defaults smaller with a TV behind them).
// Outer widths in screen-width units: iPad 249.7/236, phone 71.9/236.
let devicesScale = number("DEVICES") ?? (tvShot == nil ? 1 : 0.8)
let phoneUnit = 71.9 / 236.0
let unitWidth = 249.7 / 236.0 + phoneUnit * (1 - overlap)
let ipadScreenW = (CGFloat(W) - 2 * margin - (overlap > 0 ? 0 : gap)) / unitWidth * devicesScale
let pxPerMM = ipadScreenW / 236.0
let ipadScreenH = ipadScreenW * ipadAspect
let phoneScreenH = 146.0 * pxPerMM
let phoneScreenW = phoneScreenH * phoneAspect
let ipadOuterExtra = 6.5 * pxPerMM, phoneOuterExtra = 2.6 * pxPerMM
let phoneOuterW = phoneScreenW + 2 * phoneOuterExtra
// The phone sits a little lower than the iPad when overlapping, so the stack is taller.
let phoneDrop = overlap > 0 ? 9 * pxPerMM : 0
let dockIcon = env["DOCK"].map(load)
let dockBelow = env["DOCK_POS"] == "below"
let dockGlass = env["DOCK_BG"] != "0"
let dockIconSide = ipadScreenW * CGFloat(env["DOCK_SCALE"].flatMap(Double.init) ?? 0.105)
let dockPad = dockGlass ? dockIconSide * 0.2 : 0
let dockH = dockIconSide + 2 * dockPad
// How far the dock reaches below the iPad's outer edge.
let dockReach: CGFloat = dockIcon == nil ? 0 : (dockBelow ? dockH + dockIconSide * 0.35 : dockH / 2)
let groupH = ipadScreenH + 2 * ipadOuterExtra + max(phoneDrop, dockReach)
// The TV: its upper part shows above the iPad, the rest is behind it.
let tvOuterW = CGFloat(W) * (number("TV_WIDTH") ?? 0.8)
let tvScreenW = tvOuterW / (1 + 2 * (tvBezelShare + tvEdgeShare))
let tvScreenH = tvShot.map { tvScreenW * CGFloat($0.height) / CGFloat($0.width) } ?? 0
let tvFrame = (tvOuterW - tvScreenW) / 2
let tvOuterH = tvScreenH + 2 * tvFrame
let tvShown = tvShot == nil ? 0 : tvOuterH * (1 - (number("TV_COVER") ?? 0.4))
// Center logo (+ TV) + devices together.
let logoGap = logo == nil ? 0 : margin * (tvShot == nil ? 1.1 : 0.8)
let stackH = logoH + logoGap + tvShown + groupH
let stackTop = (CGFloat(H) - stackH) / 2
let groupTop = stackTop + logoH + logoGap + tvShown
// Without a TV the iPad starts at the margin (as it always has); with one, the pair is centered.
let groupW = 2 * ipadOuterExtra + ipadScreenW + (overlap > 0 ? -phoneOuterW * overlap : gap) + phoneOuterW
let groupLeft = tvShot == nil ? margin : (CGFloat(W) - groupW) / 2 + CGFloat(W) * (number("DEVICES_X") ?? 0)
let ipadScreen = CGRect(x: groupLeft + ipadOuterExtra, y: groupTop + ipadOuterExtra, width: ipadScreenW, height: ipadScreenH)
// The phone stands beside it, bottoms aligned.
let phoneScreen = CGRect(x: ipadScreen.maxX + ipadOuterExtra + (overlap > 0 ? -phoneOuterW * overlap : gap) + phoneOuterExtra,
                         y: ipadScreen.maxY + ipadOuterExtra + phoneDrop - phoneOuterExtra - phoneScreenH,
                         width: phoneScreenW, height: phoneScreenH)

// MARK: Drawing, back to front

layer("Background") {
    // Aspect-fill the background (it's blurred, so scaling up is fine).
    let fill = max(CGFloat(W) / CGFloat(background.width), CGFloat(H) / CGFloat(background.height))
    let bgSize = CGSize(width: CGFloat(background.width) * fill, height: CGFloat(background.height) * fill)
    drawImage(background, in: CGRect(x: (CGFloat(W) - bgSize.width) / 2, y: (CGFloat(H) - bgSize.height) / 2, width: bgSize.width, height: bgSize.height))
}
if let logo {
    layer("Logo") {
        // With an icon: [icon] [wordmark], centered as one lockup, icon as tall as the wordmark.
        let icon = env["ICON"].map(load)
        let iconSide = logoH * 1.0, iconGap = logoH * 0.28
        let lockupW = logoW + (icon == nil ? 0 : iconSide + iconGap)
        let lockupX = (CGFloat(W) - lockupW) / 2
        if let icon {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: iconSide * 0.03), blur: iconSide * 0.12, color: CGColor(gray: 0, alpha: 0.45))
            drawImage(icon, in: CGRect(x: lockupX, y: stackTop, width: iconSide, height: iconSide))
            ctx.restoreGState()
        }
        drawImage(logo, in: CGRect(x: lockupX + (icon == nil ? 0 : iconSide + iconGap), y: stackTop, width: logoW, height: logoH))
    }
}
if let tvShot {
    layer("Apple TV") {
        let x = (CGFloat(W) - tvOuterW) / 2 + CGFloat(W) * (number("TV_X") ?? 0) + tvFrame
        let y = stackTop + logoH + logoGap + tvFrame
        television(screen: CGRect(x: x, y: y, width: tvScreenW, height: tvScreenH), image: tvShot, stand: env["TV_STAND"] == "1")
    }
}
layer("iPad") {
    device(screen: ipadScreen, image: ipadShot, bezel: 5.6 * pxPerMM, screenRadius: 18 * pxPerMM / 2.2, rim: 0.9 * pxPerMM)
}
layer("iPhone") {
    device(screen: phoneScreen, image: phoneShot, bezel: 1.7 * pxPerMM, screenRadius: 10.5 * pxPerMM, rim: 0.9 * pxPerMM,
           // Simulator screenshots already include the island; real device screenshots don't.
           island: env["NO_ISLAND"] == nil ? CGSize(width: 21 * pxPerMM, height: 6.2 * pxPerMM) : nil)
}
// Dock: frosted glass (blurred backdrop + white wash) holding the app icon, centered on the iPad.
if let dockIcon {
    layer("App icon") {
        let ipadBottom = ipadScreen.maxY + ipadOuterExtra
        let dockW = dockIconSide + 2 * dockPad
        let dockY = dockBelow ? ipadBottom + dockIconSide * 0.35 : ipadBottom - dockH / 2
        let dock = CGRect(x: ipadScreen.midX - dockW / 2, y: dockY, width: dockW, height: dockH)
        let radius = dockH * 0.32
        let shape = CGPath(roundedRect: dock, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if dockGlass {
            // Shadow.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -dockH * 0.06), blur: dockH * 0.35, color: CGColor(gray: 0, alpha: 0.45))
            ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fillPath()
            ctx.restoreGState()
            // Blur what's behind it (everything drawn so far).
            if let snapshot = canvas.makeImage()?.cropping(to: dock.insetBy(dx: -60, dy: -60).integral) {
                let blurred = CIImage(cgImage: snapshot).clampedToExtent()
                    .applyingGaussianBlur(sigma: dockH * 0.18).cropped(to: CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
                if let out = CIContext().createCGImage(blurred, from: blurred.extent) {
                    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
                    drawImage(out, in: dock.insetBy(dx: -60, dy: -60).integral)
                    ctx.restoreGState()
                }
            }
            ctx.saveGState(); ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 1, alpha: 0.16)); ctx.fillPath(); ctx.restoreGState()
            ctx.saveGState(); ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.32)); ctx.setLineWidth(max(2, dockH * 0.012)); ctx.strokePath(); ctx.restoreGState()
        }
        // The icon, with its own shadow when there's no tile under it.
        ctx.saveGState()
        if !dockGlass { ctx.setShadow(offset: CGSize(width: 0, height: -dockIconSide * 0.04), blur: dockIconSide * 0.18, color: CGColor(gray: 0, alpha: 0.5)) }
        drawImage(dockIcon, in: CGRect(x: dock.minX + dockPad, y: dock.minY + dockPad, width: dockIconSide, height: dockIconSide))
        ctx.restoreGState()
    }
}

// MARK: Output

func writePNG(_ image: CGImage, _ path: String) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    try! (data as Data).write(to: URL(fileURLWithPath: path))
    return data as Data
}
_ = writePNG(canvas.makeImage()!, args[4])
print("wrote \(args[4]) \(W)x\(H)")

if let layersDir {
    try! FileManager.default.createDirectory(atPath: layersDir, withIntermediateDirectories: true)
    // One <image> per layer, each in a named group (Figma names layers after the group's id).
    var svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(W)" height="\(H)" viewBox="0 0 \(W) \(H)">

    """
    for (i, layer) in layers.enumerated() {
        let file = "\(i + 1) \(layer.name).png"
        let png = writePNG(layer.image, (layersDir as NSString).appendingPathComponent(file))
        let f = layer.frame
        svg += "  <g id=\"\(layer.name)\">\n    <image x=\"\(Int(f.minX))\" y=\"\(Int(f.minY))\" width=\"\(Int(f.width))\" height=\"\(Int(f.height))\" "
            + "xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>\n  </g>\n"
        print("layer \(file) at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
    }
    svg += "</svg>\n"
    let svgPath = (layersDir as NSString).appendingPathComponent("layers.svg")
    try! svg.write(toFile: svgPath, atomically: true, encoding: .utf8)
    print("wrote \(svgPath)")
}
