import Foundation
import CoreGraphics
import ImageIO
import Accelerate

public struct PixelDiff: Sendable {
    public var width: Int
    public var height: Int
    public var psnr: Double          // dB; higher is closer. inf means identical.
    public var meanAbsError: Double  // average channel difference, 0-255
    public var maxAbsError: Int      // worst single channel difference
    public var changedPercent: Double

    public var identical: Bool { maxAbsError == 0 }
}

private func decodeRGBA(_ url: URL) throws -> (Int, Int, [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw ConversionError("cannot decode \(url.lastPathComponent)") }

    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ConversionError("cannot make bitmap context") }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

/// Decodes both images and compares them pixel by pixel. This is the only
/// encoder-independent way to talk about "how much quality was lost" — file
/// size says nothing, because different encoders spend bits differently.
public func comparePixels(_ a: URL, _ b: URL) throws -> PixelDiff {
    let (wa, ha, pa) = try decodeRGBA(a)
    let (wb, hb, pb) = try decodeRGBA(b)
    guard wa == wb, ha == hb else {
        throw ConversionError("size mismatch: \(wa)x\(ha) vs \(wb)x\(hb)")
    }

    // Alpha is 255 in both buffers for opaque photos, so it contributes zero to
    // every sum; only the divisor has to exclude it.
    var fa = [Float](repeating: 0, count: pa.count)
    var fb = [Float](repeating: 0, count: pb.count)
    vDSP.convertElements(of: pa, to: &fa)
    vDSP.convertElements(of: pb, to: &fb)

    var d = vDSP.subtract(fa, fb)
    let sumSq = Double(vDSP.sumOfSquares(d))
    vDSP.absolute(d, result: &d)
    let sumAbs = Double(vDSP.sum(d))
    let maxAbs = Int(vDSP.maximum(d))

    var changed = 0
    d.withUnsafeBufferPointer { buf in
        var i = 0
        while i < buf.count {
            if buf[i] != 0 || buf[i + 1] != 0 || buf[i + 2] != 0 { changed += 1 }
            i += 4
        }
    }

    let n = Double(wa * ha * 3)
    let mse = sumSq / n
    let psnr = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)

    return PixelDiff(width: wa, height: ha, psnr: psnr,
                     meanAbsError: sumAbs / n, maxAbsError: maxAbs,
                     changedPercent: Double(changed) / Double(wa * ha) * 100)
}
