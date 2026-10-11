// Composes an iPad (landscape) and iPhone screenshot in drawn device frames on a background.
// Usage: swift Tools/compose-device-shot.swift background.png ipad.png iphone.png out.png
// Env: SQUARE=<side> for a square canvas, LOGO=<png> centered above (ICON=<png> beside it),
//      DOCK=<png> app icon centered on the iPad's bottom edge (DOCK_POS=over|below, DOCK_SCALE=<share of iPad width>,
//      DOCK_BG=0 for the icon alone without the glass tile), OVERLAP=<0..1> phone over the iPad, NO_ISLAND=1 for simulator phone shots.
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
let square = env["SQUARE"].flatMap(Int.init)
let W = square ?? background.width, H = square ?? background.height
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
// Work top-down like a screen.
ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)

func drawImage(_ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

// Aspect-fill the background (it's blurred, so scaling up is fine).
let fill = max(CGFloat(W) / CGFloat(background.width), CGFloat(H) / CGFloat(background.height))
let bgSize = CGSize(width: CGFloat(background.width) * fill, height: CGFloat(background.height) * fill)
drawImage(background, in: CGRect(x: (CGFloat(W) - bgSize.width) / 2, y: (CGFloat(H) - bgSize.height) / 2, width: bgSize.width, height: bgSize.height))

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

// Real proportions: iPad Pro 11" (M4) is ~249.7 × 177.5 mm (screen ~236 mm wide), iPhone 17 Pro ~150 × 71.9 mm.
let ipadAspect = CGFloat(ipadShot.height) / CGFloat(ipadShot.width)
let phoneAspect = CGFloat(phoneShot.width) / CGFloat(phoneShot.height)
let margin = CGFloat(W) * 0.05, gap = CGFloat(W) * 0.025
// Optional overlap: the phone stands in front of the iPad's right edge (fraction of the phone's width).
let overlap = CGFloat(env["OVERLAP"].flatMap(Double.init) ?? 0)
var logo: CGImage?, logoW: CGFloat = 0, logoH: CGFloat = 0
if let logoPath = env["LOGO"] {
    logo = load(logoPath)
    logoW = CGFloat(W) * 0.32
    logoH = logoW * CGFloat(logo!.height) / CGFloat(logo!.width)
}
// Widest iPad screen such that iPad + gap + phone (minus overlap) fill the width between margins.
// Outer widths in screen-width units: iPad 249.7/236, phone 71.9/236.
let phoneUnit = 71.9 / 236.0
let unitWidth = 249.7 / 236.0 + phoneUnit * (1 - overlap)
let ipadScreenW = (CGFloat(W) - 2 * margin - (overlap > 0 ? 0 : gap)) / unitWidth
let pxPerMM = ipadScreenW / 236.0
let ipadScreenH = ipadScreenW * ipadAspect
let phoneScreenH = 146.0 * pxPerMM
let phoneScreenW = phoneScreenH * phoneAspect
let ipadOuterExtra = 6.5 * pxPerMM, phoneOuterExtra = 2.6 * pxPerMM
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
// Center logo + devices together.
let logoGap = logo == nil ? 0 : margin * 1.1
let stackH = logoH + logoGap + groupH
let stackTop = (CGFloat(H) - stackH) / 2
if let logo {
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
let groupTop = stackTop + logoH + logoGap
let ipadScreen = CGRect(x: margin + ipadOuterExtra, y: groupTop + ipadOuterExtra, width: ipadScreenW, height: ipadScreenH)
device(screen: ipadScreen, image: ipadShot, bezel: 5.6 * pxPerMM, screenRadius: 18 * pxPerMM / 2.2, rim: 0.9 * pxPerMM)
// Dock: frosted glass (blurred backdrop + white wash) holding the app icon, centered on the iPad.
if let dockIcon {
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
    // Blur what's behind it.
    if let snapshot = ctx.makeImage()?.cropping(to: dock.insetBy(dx: -60, dy: -60).integral) {
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

// The phone stands beside it, bottoms aligned.
let phoneOuterW = phoneScreenW + 2 * phoneOuterExtra
let phoneScreen = CGRect(x: ipadScreen.maxX + ipadOuterExtra + (overlap > 0 ? -phoneOuterW * overlap : gap) + phoneOuterExtra,
                         y: ipadScreen.maxY + ipadOuterExtra + phoneDrop - phoneOuterExtra - phoneScreenH,
                         width: phoneScreenW, height: phoneScreenH)
device(screen: phoneScreen, image: phoneShot, bezel: 1.7 * pxPerMM, screenRadius: 10.5 * pxPerMM, rim: 0.9 * pxPerMM,
       // Simulator screenshots already include the island; real device screenshots don't.
       island: env["NO_ISLAND"] == nil ? CGSize(width: 21 * pxPerMM, height: 6.2 * pxPerMM) : nil)

let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("wrote \(args[4]) \(W)x\(H)")
