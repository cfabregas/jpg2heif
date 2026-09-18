import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: makeicon <source image> <output .iconset dir>

let srcURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("cannot read \(srcURL.path)")
}

/// Finds the artwork inside its padding. Anything transparent, or near enough
/// to white to be the backdrop the art was exported on, counts as margin.
func contentBounds(of image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return CGRect(x: 0, y: 0, width: w, height: h) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let a = Int(buf[i + 3])
            if a < 24 { continue }
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            if r > 243 && g > 243 && b > 243 { continue }   // white backdrop
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: w, height: h)
    }
    // The context is bottom-up while the scan was top-down.
    return CGRect(x: minX, y: h - 1 - maxY,
                  width: maxX - minX + 1, height: maxY - minY + 1)
}

// Padded back out to a square rather than stretched: a non-uniform scale to
// fill the canvas was visibly distorting the artwork.
var crop = contentBounds(of: art)
let side = max(crop.width, crop.height)
crop = CGRect(x: crop.midX - side / 2, y: crop.midY - side / 2, width: side, height: side)
    .intersection(CGRect(x: 0, y: 0, width: art.width, height: art.height))

guard let trimmed = art.cropping(to: crop) else { fatalError("crop failed") }
FileHandle.standardError.write(
    "source \(art.width)x\(art.height) -> content \(Int(crop.width))x\(Int(crop.height)) at (\(Int(crop.minX)),\(Int(crop.minY)))\n"
        .data(using: .utf8)!)

func render(_ size: Int, to url: URL) {
    let S = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The art already carries its own rounded corners; clipping to the macOS
    // radius keeps stray pixels from poking outside them.
    let r = S * 0.2237
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                       cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.draw(trimmed, in: CGRect(x: 0, y: 0, width: S, height: S))

    guard let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dst, img, nil)
    _ = CGImageDestinationFinalize(dst)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    render(px, to: outDir.appendingPathComponent("\(name).png"))
}
print("wrote iconset")
