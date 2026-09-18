import Foundation
import UniformTypeIdentifiers
import CoreImage
import ImageIO
import ConversionKit

func printReport(_ r: ImageReport, label: String) {
    print("\(label): \(URL(fileURLWithPath: r.path).lastPathComponent)")
    print("  type        \(r.uti)")
    print("  pixels      \(r.pixelWidth) x \(r.pixelHeight)   orientation \(r.orientation)")
    print("  color       \(r.colorSpace)")
    print("  size        \(formatBytes(r.fileBytes))")
    if let g = r.gainMap {
        let sz = g.byteCount >= 0 ? formatBytes(g.byteCount) : "data not exposed"
        print("  gain map    \(g.kind.rawValue)  \(g.width)x\(g.height)  \(sz)")
    } else {
        print("  gain map    none (SDR)")
    }
    print("  exif \(r.hasEXIF ? "yes" : "no")   gps \(r.hasGPS ? "yes" : "no")   depth \(r.hasDepth ? "yes" : "no")")
}

// A synthetic HDR JPEG, so the pipeline can be exercised without a camera roll.
func makeSample(_ outURL: URL, hdr wantHDR: Bool) throws {
    let extent = CGRect(x: 0, y: 0, width: 1024, height: 768)
    let grad = CIFilter(name: "CISmoothLinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 1024, y: 768),
        "inputColor0": CIColor(red: 0.02, green: 0.05, blue: 0.2),
        "inputColor1": CIColor(red: 1.0, green: 0.95, blue: 0.7),
    ])!.outputImage!.cropped(to: extent)
    let sun = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(x: 780, y: 580), "inputRadius0": 40.0, "inputRadius1": 190.0,
        "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
        "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
    ])!.outputImage!.cropped(to: extent)
    let sdr = sun.composited(over: grad).cropped(to: extent)

    var options: [CIImageRepresentationOption: Any] = [
        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92
    ]
    if wantHDR {
        let boosted = sun.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 6, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 6, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 6, w: 0),
        ]).composited(over: grad).cropped(to: extent)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        options[.hdrImage] = boosted.matchedFromWorkingSpace(to: linear) ?? boosted
    }
    try CIContext().writeJPEGRepresentation(
        of: sdr, to: outURL, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options)
}

/// Converts one photo across a range of quality values so the size curve is
/// visible. Useful for matching another encoder's output size.
func sweep(_ inURL: URL) throws {
    let before = try inspect(inURL)
    print("input: \(inURL.lastPathComponent)  \(before.pixelWidth)x\(before.pixelHeight)  "
          + formatBytes(before.fileBytes) + (before.isHDR ? "  HDR" : "  SDR"))
    print("")
    print("  quality    size        vs original")
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("sweep-\(UUID().uuidString).heic")
    defer { try? FileManager.default.removeItem(at: tmp) }

    for q in stride(from: 0.50, through: 1.0, by: 0.05) {
        let r = try convertToHEIC(from: inURL, to: tmp, quality: q)
        let pct = before.fileBytes > 0
            ? Double(r.after.fileBytes) / Double(before.fileBytes) * 100 : 0
        let hdr = r.after.isHDR ? " HDR" : ""
        let size = formatBytes(r.after.fileBytes).padding(toLength: 9, withPad: " ", startingAt: 0)
        print(String(format: "  %5.0f%%    %@  %5.1f%%%@", q * 100, size, pct, hdr))
    }
}

/// Re-encodes the image over and over at one quality, measuring each
/// generation against the untouched original. Answers "how many round trips
/// before it shows".
func generations(_ inURL: URL, quality: Double, count: Int) throws {
    let before = try inspect(inURL)
    print("source: \(inURL.lastPathComponent)  \(before.pixelWidth)x\(before.pixelHeight)  "
          + formatBytes(before.fileBytes))
    print("quality: \(Int(quality * 100))%")
    print("")
    print("  gen   size        PSNR vs original   mean error   changed")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var current = inURL
    for g in 1...count {
        let out = dir.appendingPathComponent("g\(g).heic")
        _ = try convertToHEIC(from: current, to: out, quality: quality)
        let d = try comparePixels(inURL, out)
        let size = formatBytes(((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0)
        print(String(format: "  %3d   %-10@  %8.2f dB       %8.3f     %5.1f%%",
                     g, size as NSString, d.psnr, d.meanAbsError, d.changedPercent))
        current = out
    }
}

func usage() -> Never {
    print("""
    heifconv inspect    <file>
    heifconv convert    <in.jpg> <out.heic> [quality 0-1, default 0.85] [--max-edge N] [--no-hdr]
    heifconv makesample <out.jpg> [--sdr]
    heifconv sweep      <in.jpg>
    heifconv diff       <a> <b>
    heifconv generations <in> <quality> <count>
    heifconv tojpeg     <in> <out.jpg> <quality>
    heifconv totiff     <in> <out.tif>
    """)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())

do {
    guard let cmd = args.first else { usage() }
    switch cmd {
    case "inspect":
        guard args.count >= 2 else { usage() }
        printReport(try inspect(URL(fileURLWithPath: args[1])), label: "file")

    case "generations":
        guard args.count >= 4 else { usage() }
        try generations(URL(fileURLWithPath: args[1]),
                        quality: Double(args[2]) ?? 0.8,
                        count: Int(args[3]) ?? 10)

    case "diff":
        guard args.count >= 3 else { usage() }
        let d = try comparePixels(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]))
        print("  \(d.width) x \(d.height)")
        if d.identical {
            print("  identical — pixel for pixel")
        } else {
            print(String(format: "  PSNR            %.2f dB", d.psnr))
            print(String(format: "  mean error      %.3f / 255", d.meanAbsError))
            print("  worst error     \(d.maxAbsError) / 255")
            print(String(format: "  pixels changed  %.1f%%", d.changedPercent))
        }

    case "tojpeg":
        guard args.count >= 3 else { usage() }
        let q = args.count >= 4 ? (Double(args[3]) ?? 0.8) : 0.8
        let u = URL(fileURLWithPath: args[1])
        guard let img = CIImage(contentsOf: u, options: [.applyOrientationProperty: true]) else {
            throw ConversionError("cannot decode")
        }
        try CIContext().writeJPEGRepresentation(
            of: img, to: URL(fileURLWithPath: args[2]),
            colorSpace: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String): q])
        print("wrote \(args[2]) at q=\(q)")

    case "totiff":
        guard args.count >= 3 else { usage() }
        let u = URL(fileURLWithPath: args[1])
        guard let img = CIImage(contentsOf: u, options: [.applyOrientationProperty: true]) else {
            throw ConversionError("cannot decode")
        }
        try CIContext().writeTIFFRepresentation(
            of: img, to: URL(fileURLWithPath: args[2]), format: .RGBA8,
            colorSpace: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        print("wrote \(args[2])")

    case "sweep":
        guard args.count >= 2 else { usage() }
        try sweep(URL(fileURLWithPath: args[1]))

    case "makesample":
        guard args.count >= 2 else { usage() }
        let wantHDR = !args.contains("--sdr")
        try makeSample(URL(fileURLWithPath: args[1]), hdr: wantHDR)
        print("wrote \(args[1]) (\(wantHDR ? "HDR" : "SDR"))")

    case "convert":
        guard args.count >= 3 else { usage() }
        let q = args.count >= 4 ? (Double(args[3]) ?? 0.85) : 0.85
        let maxEdge = args.firstIndex(of: "--max-edge").flatMap { i in
            i + 1 < args.count ? Int(args[i + 1]) : nil
        }
        let r = try convertToHEIC(from: URL(fileURLWithPath: args[1]),
                                  to: URL(fileURLWithPath: args[2]), quality: q,
                                  maxLongEdge: maxEdge,
                                  preserveHDR: !args.contains("--no-hdr"))
        printReport(r.before, label: "input ")
        print("")
        printReport(r.after, label: "output")
        print("")
        let pct = r.before.fileBytes > 0 ? Double(r.savedBytes) / Double(r.before.fileBytes) * 100 : 0
        print(String(format: "  delta       %@ (%.1f%%) %@",
                     formatBytes(abs(r.savedBytes)), abs(pct), r.savedBytes >= 0 ? "smaller" : "LARGER"))
        print("")
        if r.passed {
            print("  VERIFY      pass — safe to delete original")
        } else {
            print("  VERIFY      FAIL — keep original")
            for f in r.failures { print("              - \(f)") }
            exit(1)
        }

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
