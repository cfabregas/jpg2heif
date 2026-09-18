import Foundation
import AppKit

enum LogStore {
    static var directory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jpg2heif", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))?
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            } ?? []
    }

    static var totalBytes: Int {
        files().reduce(0) { sum, u in
            sum + (((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
        }
    }

    static func reveal() {
        let all = files()
        if all.isEmpty {
            NSWorkspace.shared.open(directory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([all[0]])
        }
    }

    /// Log files only — this never touches photos.
    static func clear() {
        for u in files() { try? FileManager.default.removeItem(at: u) }
    }
}

/// Rough size estimate from the quality slider, interpolated between sizes
/// actually measured on two 24MP photos (one SDR, one with an HDR gain map).
/// The spread between those two is what makes this a range rather than a number.
enum SizeEstimate {
    // quality -> (SDR output as % of source, HDR output as % of source)
    private static let table: [(q: Double, low: Double, high: Double)] = [
        (0.50, 19.6, 48.3),
        (0.55, 32.9, 55.7),
        (0.60, 38.2, 59.0),
        (0.65, 50.0, 66.4),
        (0.70, 50.0, 66.4),
        (0.75, 56.2, 70.1),
        (0.80, 62.1, 73.7),
        (0.85, 62.1, 73.7),
        (0.90, 93.7, 93.8),
        (0.95, 146.8, 150.6),
        (1.00, 305.3, 347.0),
    ]

    /// Returns the expected output size as a fraction of the source, low and high.
    static func outputFraction(quality q: Double) -> (Double, Double) {
        if q <= table[0].q { return (table[0].low / 100, table[0].high / 100) }
        if q >= table[table.count - 1].q {
            let t = table[table.count - 1]
            return (t.low / 100, t.high / 100)
        }
        for i in 0..<(table.count - 1) {
            let a = table[i], b = table[i + 1]
            if q >= a.q && q <= b.q {
                let t = (q - a.q) / (b.q - a.q)
                return ((a.low + (b.low - a.low) * t) / 100,
                        (a.high + (b.high - a.high) * t) / 100)
            }
        }
        return (0.62, 0.74)
    }

    /// Bytes saved, low and high. Negative means the output is expected to grow.
    /// Downscaling is folded in per photo, because output size tracks pixel
    /// count and only some photos are over the limit.
    static func savedRange(items: [(bytes: Int, longEdge: Int)],
                           quality: Double, maxLongEdge: Int?) -> (Int, Int) {
        let (lo, hi) = outputFraction(quality: quality)
        var outLo = 0.0, outHi = 0.0
        var total = 0
        for it in items {
            var areaFactor = 1.0
            if let limit = maxLongEdge, it.longEdge > limit, it.longEdge > 0 {
                let s = Double(limit) / Double(it.longEdge)
                areaFactor = s * s
            }
            outLo += Double(it.bytes) * lo * areaFactor
            outHi += Double(it.bytes) * hi * areaFactor
            total += it.bytes
        }
        // A smaller output means a bigger saving, so the bounds swap.
        return (Int(Double(total) - outHi), Int(Double(total) - outLo))
    }
}
