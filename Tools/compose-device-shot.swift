// Composes an iPad (landscape) and iPhone screenshot in drawn device frames on a background.
// Usage: swift compose.swift background.png ipad.png iphone.png out.png
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
func load(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
let background = load(args[1]), ipadShot = load(args[2]), phoneShot = load(args[3])
let W = background.width, H = background.height
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

drawImage(background, in: CGRect(x: 0, y: 0, width: W, height: H))

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

// Real proportions: iPad Pro 11" (M4) is ~249.7 × 177.5 mm, iPhone 17 Pro ~150 × 71.9 mm.
let ipadScreenW: CGFloat = 1880
let pxPerMM = ipadScreenW / 236.0           // the 11" screen is ~236 mm wide
let ipadScreenH = ipadScreenW * CGFloat(ipadShot.height) / CGFloat(ipadShot.width)
let phoneScreenH = 146.0 * pxPerMM          // iPhone screen height
let phoneScreenW = phoneScreenH * CGFloat(phoneShot.width) / CGFloat(phoneShot.height)

let gap: CGFloat = 70
let ipadOuterExtra: CGFloat = 6.5 * pxPerMM
let total = ipadScreenW + 2 * ipadOuterExtra + gap + phoneScreenW + 2 * 2.6 * pxPerMM
let left = (CGFloat(W) - total) / 2
let ipadScreen = CGRect(x: left + ipadOuterExtra, y: (CGFloat(H) - ipadScreenH) / 2 - 40, width: ipadScreenW, height: ipadScreenH)
device(screen: ipadScreen, image: ipadShot, bezel: 5.6 * pxPerMM, screenRadius: 18 * pxPerMM / 2.2, rim: 0.9 * pxPerMM)

// The phone stands slightly forward and lower, its bottom just below the iPad's.
let phoneScreen = CGRect(x: ipadScreen.maxX + ipadOuterExtra + gap + 2.6 * pxPerMM,
                         y: ipadScreen.maxY + ipadOuterExtra - phoneScreenH + 60,
                         width: phoneScreenW, height: phoneScreenH)
device(screen: phoneScreen, image: phoneShot, bezel: 1.7 * pxPerMM, screenRadius: 10.5 * pxPerMM, rim: 0.9 * pxPerMM,
       island: CGSize(width: 21 * pxPerMM, height: 6.2 * pxPerMM))

let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("wrote \(args[4]) \(W)x\(H)")
