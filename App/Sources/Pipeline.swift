import Foundation
import Photos
import UniformTypeIdentifiers

@MainActor
@Observable
final class Pipeline {
    var running = false
    var cancelled = false
    var progress: Double = 0
    var currentNote = ""
    var summary = RunSummary()
    var finished = false

    var quality: Double = 0.80
    var skipIfNotSmaller = true
    var optimizeSize = true
    var maxLongEdge = 6000
    var destination: Destination = .sameAsOriginal

    /// Originals that passed verification and are therefore safe to delete.
    var deletable: [PhotoItem] = []
    /// Only what this run touched. Without it the results list keeps showing
    /// photos left over from an earlier run.
    var processed: [PhotoItem] = []
    var logURL: URL?

    private let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("jpg2heif", isDirectory: true)

    // MARK: Run

    func run(items: [PhotoItem], library: PhotoLibrary) async {
        running = true
        cancelled = false
        finished = false
        progress = 0
        summary = RunSummary()
        deletable = []
        processed = items
        cachedNewAlbum = nil
        cachedNewAlbumName = nil
        for i in items { i.state = .pending; i.outcome = nil; i.errorText = nil }
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        var logRows: [[String: Any]] = []
        let total = max(items.count, 1)

        for (i, item) in items.enumerated() {
            if cancelled { break }
            progress = Double(i) / Double(total)
            currentNote = "第 \(i + 1) / \(items.count) 张"
            item.state = .working

            do {
                let row = try await process(item, library: library)
                logRows.append(row)
            } catch {
                item.state = .failed
                item.errorText = "\(error)"
                summary.failed += 1
                logRows.append(["id": item.id, "status": "error", "error": "\(error)"])
            }
        }

        progress = 1
        currentNote = cancelled ? "已取消" : "完成"
        writeLog(logRows)
        running = false
        finished = true
    }

    private func process(_ item: PhotoItem, library: PhotoLibrary) async throws -> [String: Any] {
        // 1. Pull the exact original bytes out of the library.
        let inURL = tmpDir.appendingPathComponent("\(UUID().uuidString).in")
        let outURL = tmpDir.appendingPathComponent("\(UUID().uuidString).heic")
        defer {
            try? FileManager.default.removeItem(at: inURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        let sourceLabel = try await exportOriginal(item, to: inURL)

        // 2. Convert, carrying the gain map across when there is one.
        let outcome = try convertToHEIC(from: inURL, to: outURL, quality: quality,
                                        maxLongEdge: optimizeSize ? maxLongEdge : nil)
        item.outcome = outcome

        guard outcome.passed else {
            item.state = .failed
            item.errorText = outcome.failures.joined(separator: "; ")
            summary.failed += 1
            return ["id": item.id, "status": "verify_failed", "failures": outcome.failures,
                    "source_type": sourceLabel,
                    "orientation": outcome.before.orientation,
                    "has_raw": item.hasRAW]
        }

        if skipIfNotSmaller && outcome.savedBytes <= 0 {
            item.state = .skipped
            summary.skipped += 1
            return ["id": item.id, "status": "skipped_not_smaller",
                    "before": outcome.before.fileBytes, "after": outcome.after.fileBytes]
        }

        // 3. Import it and file it into the destination album.
        let targets = try destinationCollections(for: item)
        let newID = try await createAsset(from: outURL, like: item.asset,
                                          named: heicName(for: item), in: targets)

        // 4. Confirm the new asset really landed before the original becomes deletable.
        // Compare the dimensions as an unordered pair: PHAsset reports display
        // size, which can be the transpose of the file's stored size.
        let want = [outcome.after.pixelWidth, outcome.after.pixelHeight].sorted()
        guard let newID,
              let created = PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject,
              [created.pixelWidth, created.pixelHeight].sorted() == want else {
            item.state = .failed
            item.errorText = "新照片未能写入图库"
            summary.failed += 1
            return ["id": item.id, "status": "import_failed"]
        }

        item.newAssetID = newID
        item.state = .verified
        summary.converted += 1
        summary.savedBytes += outcome.savedBytes
        if outcome.before.isHDR { summary.hdrPreserved += 1 }

        // A shared-album original stays put no matter what: PhotoKit refuses to
        // delete it, so it never reaches the delete list.
        if item.asset.canPerform(.delete) {
            deletable.append(item)
        } else {
            summary.notDeletable += 1
        }

        return [
            "id": item.id,
            "status": "ok",
            "new_id": newID,
            "before_bytes": outcome.before.fileBytes,
            "after_bytes": outcome.after.fileBytes,
            "hdr": outcome.before.isHDR,
            "gain_map": outcome.before.gainMap?.kind.rawValue ?? "none",
            "source_type": sourceLabel,
            "has_raw": item.hasRAW,
            "orientation": outcome.before.orientation,
            "albums": targets.map { $0.localizedTitle ?? "" },
        ]
    }

    /// Writes the bytes this photo should be converted from into `url`,
    /// returning a label for the log.
    private func exportOriginal(_ item: PhotoItem, to url: URL) async throws -> String {
        let resources = PHAssetResource.assetResources(for: item.asset)

        // An edited photo is converted as the user sees it, not as it was shot.
        // Otherwise take the JPEG or PNG specifically: on a RAW+JPEG pair the
        // .photo resource can be the RAW.
        let source = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: {
                ($0.type == .photo || $0.type == .alternatePhoto)
                    && ($0.uniformTypeIdentifier == UTType.jpeg.identifier
                        || $0.uniformTypeIdentifier == UTType.png.identifier) })
            ?? resources.first(where: { $0.type == .photo })

        if let source {
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true   // originals may live only in iCloud
            try await PHAssetResourceManager.default().writeData(
                for: source, toFile: url, options: opts)
            return "\(source.uniformTypeIdentifier) (resource \(source.type.rawValue))"
        }

        // Shared-album assets are cloud references that list no resources at
        // all; their bytes only come back through the image manager.
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.version = .current
        opts.deliveryMode = .highQualityFormat
        opts.isSynchronous = false

        let (data, uti): (Data, String) = try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(
                for: item.asset, options: opts
            ) { data, uti, _, info in
                if let data {
                    cont.resume(returning: (data, uti ?? "?"))
                } else {
                    let why = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                        ?? "图库没有返回这张照片的数据"
                    cont.resume(throwing: ConversionError(why))
                }
            }
        }
        try data.write(to: url)
        return "\(uti) (image data)"
    }

    // MARK: Destination

    private func destinationCollections(for item: PhotoItem) throws -> [PHAssetCollection] {
        switch destination {
        case .libraryOnly:
            return []
        case .album(let ref):
            return [ref.collection]
        case .newAlbum(let name):
            // Cached so one run files everything into a single album — but the
            // cache has to track the name, or renaming keeps writing into the
            // album made the first time.
            if let existing = cachedNewAlbum, cachedNewAlbumName == name {
                return [existing]
            }
            let album = try existingAlbum(named: name) ?? createAlbum(named: name)
            cachedNewAlbum = album
            cachedNewAlbumName = name
            return [album]
        case .sameAsOriginal:
            let found = PHAssetCollection.fetchAssetCollectionsContaining(
                item.asset, with: .album, options: nil)
            var out: [PHAssetCollection] = []
            found.enumerateObjects { c, _, _ in
                if c.canPerform(.addContent) { out.append(c) }
            }
            return out
        }
    }

    private var cachedNewAlbum: PHAssetCollection?
    private var cachedNewAlbumName: String?

    /// Running twice with the same name should collect the photos together
    /// rather than leaving two albums with identical titles.
    private func existingAlbum(named name: String) -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "localizedTitle == %@", name)
        let found = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: opts)
        var match: PHAssetCollection?
        found.enumerateObjects { c, _, stop in
            if c.canPerform(.addContent) { match = c; stop.pointee = true }
        }
        return match
    }

    private func createAlbum(named name: String) throws -> PHAssetCollection {
        var placeholder: PHObjectPlaceholder?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = req.placeholderForCreatedAssetCollection
        }
        guard let id = placeholder?.localIdentifier,
              let c = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ConversionError("无法创建相簿「\(name)」")
        }
        return c
    }

    // MARK: Import

    /// Same stem as the original, with the extension the file now actually is.
    private func heicName(for item: PhotoItem) -> String? {
        guard let name = item.originalFilename, !name.isEmpty else { return nil }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? nil : stem + ".heic"
    }

    private func createAsset(from url: URL, like original: PHAsset, named filename: String?,
                             in collections: [PHAssetCollection]) async throws -> String? {
        final class Box: @unchecked Sendable { var id: String? }
        let box = Box()

        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let o = PHAssetResourceCreationOptions()
            o.shouldMoveFile = false
            // Without this the asset is named after the temporary file, which
            // is a UUID.
            o.originalFilename = filename
            req.addResource(with: .photo, fileURL: url, options: o)
            req.creationDate = original.creationDate
            req.location = original.location
            req.isFavorite = original.isFavorite

            guard let placeholder = req.placeholderForCreatedAsset else { return }
            box.id = placeholder.localIdentifier
            for c in collections {
                PHAssetCollectionChangeRequest(for: c)?.addAssets([placeholder] as NSArray)
            }
        }
        return box.id
    }

    // MARK: Delete

    /// macOS shows its own confirmation on top of this, and the assets land in
    /// "Recently Deleted" for 30 days.
    func deleteOriginals(_ items: [PhotoItem]) async throws {
        let assets = items.map(\.asset)
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        for i in items { i.state = .deleted }
        deletable.removeAll { d in items.contains { $0.id == d.id } }
    }

    // MARK: Log

    private func writeLog(_ rows: [[String: Any]]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = LogStore.directory.appendingPathComponent("run-\(stamp).json")
        let payload: [String: Any] = [
            "date": stamp,
            "quality": quality,
            "destination": destination.label,
            "max_long_edge": optimizeSize ? maxLongEdge : 0,
            "converted": summary.converted,
            "skipped": summary.skipped,
            "failed": summary.failed,
            "saved_bytes": summary.savedBytes,
            "items": rows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            logURL = url
        }
    }
}
