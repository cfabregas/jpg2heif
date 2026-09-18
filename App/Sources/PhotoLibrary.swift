import Foundation
import Photos
import AppKit
import UniformTypeIdentifiers
import CoreImage

@MainActor
@Observable
final class PhotoLibrary {
    var authStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var albumsByKind: [(kind: AlbumKind, albums: [AlbumRef])] = []
    var items: [PhotoItem] = []

    var scanning = false
    var scanProgress: Double = 0
    var scanNote = ""

    var scope: LibraryScope = .allPhotos

    private let imageManager = PHCachingImageManager()

    /// Flat list, for the places that just need "somewhere I can write to".
    var albums: [AlbumRef] { albumsByKind.flatMap(\.albums) }

    // MARK: Authorization

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authStatus = status
        if status == .authorized || status == .limited {
            await loadAlbums()
            await loadPhotos()
        }
    }

    // MARK: Albums

    func loadAlbums() async {
        var buckets: [String: [AlbumRef]] = [:]
        var order: [AlbumKind] = []

        // Count photos only. The grid never shows videos, so counting every
        // asset made albums of clips look like they held pictures.
        let imagesOnly = PHFetchOptions()
        imagesOnly.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        all.enumerateObjects { c, _, _ in
            let kind = AlbumKind.from(c.assetCollectionSubtype)
            let ref = AlbumRef(
                id: c.localIdentifier,
                title: c.localizedTitle ?? "未命名",
                count: PHAsset.fetchAssets(in: c, options: imagesOnly).count,
                canAddContent: c.canPerform(.addContent),
                kind: kind,
                collection: c)
            if buckets[kind.sectionTitle] == nil {
                buckets[kind.sectionTitle] = []
                order.append(kind)
            }
            buckets[kind.sectionTitle]?.append(ref)
        }

        // Ordinary albums first, then shared, then everything else.
        let rank: (AlbumKind) -> Int = { k in
            switch k {
            case .regular: 0
            case .shared: 1
            case .synced: 2
            case .imported: 3
            case .photoStream: 4
            case .other: 5
            }
        }

        albumsByKind = order
            .sorted { rank($0) < rank($1) }
            .map { kind in
                (kind, (buckets[kind.sectionTitle] ?? []).sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                })
            }
    }

    // MARK: Loading

    /// Lists every photo in scope. Deliberately does not touch each asset's
    /// resources — that is done lazily per visible tile, so opening a large
    /// library stays instant.
    func loadPhotos() async {
        scanning = true
        scanNote = "正在载入…"
        defer { scanning = false }

        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let fetch: PHFetchResult<PHAsset>
        switch scope {
        case .album(let album):
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetch = PHAsset.fetchAssets(in: album.collection, options: opts)

        case .allPhotos:
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetch = PHAsset.fetchAssets(with: opts)

        case .favorites:
            // Filtered on the fetch rather than read from the Favourites smart
            // album, so it covers the whole library either way.
            opts.predicate = NSPredicate(
                format: "mediaType == %d AND favorite == YES", PHAssetMediaType.image.rawValue)
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetch = PHAsset.fetchAssets(with: opts)

        case .notInAnyAlbum:
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetch = PHAsset.fetchAssets(with: opts)

        case .recentlyAdded:
            // Not the system's "Recently Added" smart album — that one only
            // covers a recent window, so it under-reports the library badly.
            // The whole library is fetched and re-sorted by when each asset
            // actually entered it.
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetch = PHAsset.fetchAssets(with: opts)
        }

        // Reuse the objects already loaded for these assets. Building fresh
        // ones would hand SwiftUI a blank thumbnail behind an unchanged view
        // identity, and the tile would never reload.
        let existing = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // PhotoKit has no "not in any album" predicate, so membership is
        // gathered once and subtracted. Album members total far fewer than the
        // library, and each album is a single fetch.
        var inSomeAlbum: Set<String>?
        if case .notInAnyAlbum = scope {
            scanNote = "正在统计相簿归属…"
            await Task.yield()
            var ids = Set<String>()
            // Regular albums only: being in someone else's shared album is not
            // the same as having been filed away.
            let albums = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil)
            albums.enumerateObjects { c, _, _ in
                PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in
                    ids.insert(a.localIdentifier)
                }
            }
            inSomeAlbum = ids
        }

        var result: [PhotoItem] = []
        result.reserveCapacity(fetch.count)
        fetch.enumerateObjects { a, _, _ in
            if let members = inSomeAlbum, members.contains(a.localIdentifier) { return }
            result.append(existing[a.localIdentifier] ?? PhotoItem(asset: a))
        }

        if case .recentlyAdded = scope {
            scanNote = "正在按入库时间排序…"
            await Task.yield()
            // addedDate is a real PHAsset property but is not part of the public
            // API surface, so it is read by key and sorted here rather than
            // handed to the fetch as a sort descriptor.
            let keyed = result.map { ($0, ($0.asset.value(forKey: "addedDate") as? Date) ?? .distantPast) }
            result = keyed.sorted { $0.1 > $1.1 }.map(\.0)
        }

        items = result
        scanNote = "\(result.count) 张照片"
    }

    func setScope(_ s: LibraryScope) {
        guard s != scope else { return }
        // Items are reused across scopes, so their ticks would otherwise follow
        // a photo into an album you only meant to browse.
        selectAll(false)
        scope = s
        Task {
            await loadPhotos()
            selectAll(false)
        }
    }

    /// Works out what an asset really is. Cheap: reads the resource list only.
    func classify(_ item: PhotoItem) {
        guard item.kind == .unknown else { return }
        let resources = PHAssetResource.assetResources(for: item.asset)

        item.isLivePhoto = item.asset.mediaSubtypes.contains(.photoLive)
        item.isEdited = resources.contains { $0.type == .fullSizePhoto }
        item.isDeletable = item.asset.canPerform(.delete)

        // Photos only fills these in for assets it recognised as HDR itself,
        // which in practice means HEIF. A gain-map JPEG needs the file looked
        // at, which probeHDR does lazily.
        let gain = (item.asset.value(forKey: "hdrGain") as? NSNumber)?.doubleValue ?? 0
        let flagged = (item.asset.value(forKey: "isHDR") as? Bool) ?? false
        item.isHDR = flagged || gain > 0
        if item.isHDR { item.hdrProbed = true }

        // Animation has to be ruled out first. HEIF would keep a single frame,
        // and a shared album reports its assets by the type of the rendition it
        // happens to hold, which for a GIF can come back as JPEG.
        let filename = (item.asset.value(forKey: "originalFilename") as? String)
            ?? (item.asset.value(forKey: "filename") as? String)
        item.originalFilename = filename
        let looksAnimated = item.asset.mediaSubtypes.contains(.photoAnimation)
            || (filename?.lowercased().hasSuffix(".gif") ?? false)
        if looksAnimated {
            item.kind = .animated
            return
        }

        item.hasRAW = resources.contains { r in
            guard let t = UTType(r.uniformTypeIdentifier) else { return false }
            return t.conforms(to: .rawImage)
        }

        // Only the as-shot resources decide the format. A .fullSizePhoto is the
        // edited render and is usually JPEG even for a HEIC original, so
        // including it here would misfile edited HEICs as convertible.
        let originals = resources.filter { $0.type == .photo || $0.type == .alternatePhoto }
        let convertible = originals.first {
            $0.uniformTypeIdentifier == UTType.jpeg.identifier
                || $0.uniformTypeIdentifier == UTType.png.identifier
        }

        if let c = convertible {
            item.kind = c.uniformTypeIdentifier == UTType.png.identifier ? .png : .jpeg
            item.originalBytes = (c.value(forKey: "fileSize") as? Int) ?? 0
            item.originalFilename = c.originalFilename
        } else if let o = originals.first(where: { $0.type == .photo }) {
            item.kind = .other(o.uniformTypeIdentifier)
            item.originalBytes = (o.value(forKey: "fileSize") as? Int) ?? 0
            item.originalFilename = o.originalFilename
        } else {
            // Shared-album assets are cloud references and list no resources.
            // Trust the filename's extension over the asset's reported type,
            // which describes whatever rendition is cached rather than the
            // original.
            let byName = filename.flatMap { name -> String? in
                let ext = (name as NSString).pathExtension.lowercased()
                return UTType(filenameExtension: ext)?.identifier
            }
            let uti = byName
                ?? (item.asset.value(forKey: "uniformTypeIdentifier") as? String)
            switch uti {
            case UTType.jpeg.identifier: item.kind = .jpeg
            case UTType.png.identifier:  item.kind = .png
            case let u?:                 item.kind = .other(u)
            case nil:                    item.kind = .other("?")
            }
        }
    }

    // MARK: HDR probe

    private let probeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    /// Gain map metadata sits in an APP segment near the front of the file, so
    /// only the head has to be read. Network access stays off: a photo that is
    /// not downloaded goes unprobed rather than pulling megabytes for a badge.
    func probeHDR(for item: PhotoItem) {
        guard !item.hdrProbed else { return }
        // A HEIF announces its gain map in the ftyp box at the very start of the
        // file, so 4 KB is plenty. A JPEG hides it in XMP a bit further in.
        let limit: Int
        switch item.kind {
        case .jpeg:               limit = 512 * 1024
        case .other(let u) where u == "public.heic" || u == "public.heif":
                                  limit = 4 * 1024
        default:                  return
        }
        item.hdrProbed = true

        let asset = item.asset
        probeQueue.addOperation {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let res = resources.first(where: {
                $0.type == .photo || $0.type == .alternatePhoto
            }) ?? resources.first else { return }

            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = false

            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var head = Data()
                var id: PHAssetResourceDataRequestID = 0
                var wantsCancel = false
            }
            let box = Box()
            let done = DispatchSemaphore(value: 0)

            let id = PHAssetResourceManager.default().requestData(
                for: res, options: opts,
                dataReceivedHandler: { chunk in
                    box.lock.lock()
                    if box.head.count < limit {
                        box.head.append(chunk)
                        // Without cancelling, the daemon keeps shipping the
                        // whole file across XPC even though the rest is unused.
                        if box.head.count >= limit {
                            if box.id != 0 {
                                PHAssetResourceManager.default().cancelDataRequest(box.id)
                            } else {
                                box.wantsCancel = true
                            }
                        }
                    }
                    box.lock.unlock()
                },
                completionHandler: { _ in done.signal() })

            box.lock.lock()
            box.id = id
            let cancelNow = box.wantsCancel
            box.lock.unlock()
            if cancelNow { PHAssetResourceManager.default().cancelDataRequest(id) }

            _ = done.wait(timeout: .now() + 20)

            box.lock.lock()
            let head = box.head
            box.lock.unlock()

            guard !head.isEmpty, hasGainMap(head) else { return }
            DispatchQueue.main.async { item.isHDR = true }
        }
    }

    // MARK: Thumbnails

    func loadThumbnail(for item: PhotoItem, side: CGFloat = 128) {
        classify(item)
        probeHDR(for: item)
        guard item.thumbnail == nil, !item.thumbLoading else { return }
        item.thumbLoading = true

        let opts = PHImageRequestOptions()
        // highQualityFormat calls back exactly once, so the in-flight flag can
        // always be released — opportunistic fires several times and wedges the
        // tile if the final one never arrives. fastFormat also calls back once
        // but hands over a small cached thumbnail, which looked blurry.
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: side * scale, height: side * scale)

        imageManager.requestImage(
            for: item.asset, targetSize: target,
            contentMode: .aspectFill, options: opts
        ) { image, _ in
            // PhotoKit may answer on a background queue, and mutating an
            // @Observable off the main thread leaves SwiftUI unaware of it.
            DispatchQueue.main.async {
                if let image { item.thumbnail = image }
                item.thumbLoading = false
            }
        }
    }

    /// A large rendition for the preview overlay.
    ///
    /// Goes through the image *data* rather than `requestImage`, because that
    /// hands back an already-tone-mapped SDR bitmap. Decoding with
    /// `.expandToHDR` keeps the gain map applied, and rendering into a
    /// half-float extended-range space preserves the highlights above white so
    /// an EDR display can actually show them.
    func loadPreview(for item: PhotoItem, side: CGFloat, hdr: Bool,
                     done: @escaping (NSImage?) -> Void) {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        let screenScale = NSScreen.main?.backingScaleFactor ?? 2
        let maxSide = side * screenScale

        PHImageManager.default().requestImageDataAndOrientation(
            for: item.asset, options: opts
        ) { data, _, _, _ in
            guard let data else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            // On a display without extended range, expanding the gain map only
            // pushes highlights past white where they clamp flat. The SDR base
            // image is the rendition that display is meant to show.
            var opts: [CIImageOption: Any] = [.applyOrientationProperty: true]
            if hdr { opts[.expandToHDR] = true }
            guard var image = CIImage(data: data, options: opts) else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let longEdge = max(image.extent.width, image.extent.height)
            if longEdge > maxSide, longEdge > 0 {
                let f = maxSide / longEdge
                image = image.transformed(by: CGAffineTransform(scaleX: f, y: f))
            }
            let space = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearDisplayP3
                                               : CGColorSpace.displayP3)!
            let ctx = CIContext(options: [.cacheIntermediates: false])
            guard let cg = ctx.createCGImage(image, from: image.extent,
                                             format: hdr ? .RGBAh : .RGBA8,
                                             colorSpace: space) else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async { done(ns) }
        }
    }

    // MARK: Derived

    var selectedItems: [PhotoItem] { items.filter(\.selected) }

    /// What the pipeline will actually touch: JPEGs only, RAW pairs excluded.
    var convertibleSelection: [PhotoItem] {
        selectedItems.filter { $0.kind.isConvertible }
    }
    /// Selected but skipped, so the count can be shown honestly.
    var excludedFromSelection: Int { selectedItems.count - convertibleSelection.count }

    var selectedBytes: Int { convertibleSelection.reduce(0) { $0 + $1.originalBytes } }

    var selectedTotalBytes: Int { selectedItems.reduce(0) { $0 + $1.originalBytes } }

    /// Deletion is only offered when every ticked photo can actually go.
    var selectionIsDeletable: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy(\.isDeletable)
    }

    func selectAll(_ on: Bool) { items.forEach { $0.selected = on } }

    /// Deletes whatever is ticked, converted or not. macOS puts up its own
    /// confirmation on top of this, and the assets land in Recently Deleted for
    /// 30 days. A RAW+JPEG pair is one asset, so both files go together.
    func deleteSelected() async throws {
        let assets = selectedItems.map(\.asset)
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        await loadPhotos()
        await loadAlbums()
    }

    /// Select-all has to know what everything is first, otherwise the
    /// "N will convert" count would only reflect the tiles you happened to
    /// scroll past. Classification reads local metadata only, no file I/O.
    func selectEverything() async {
        scanning = true
        scanNote = "正在识别格式…"
        defer { scanning = false }
        for (i, item) in items.enumerated() {
            classify(item)
            if i % 200 == 0 {
                scanProgress = Double(i) / Double(max(items.count, 1))
                await Task.yield()
            }
        }
        scanProgress = 1
        items.forEach { $0.selected = true }
        let n = items.filter { $0.kind.isConvertible }.count
        scanNote = "\(items.count) 张照片，其中 \(n) 张 JPEG"
    }
}


/// Scans raw bytes for the markers a gain map leaves in the file header.
/// Decoding the block to a String first was measured at ~9 ms per photo against
/// 0.02 ms this way, which matters when every visible tile triggers a probe.
private let gainMapMarkers: [[UInt8]] = [
    Array("hdrgm:".utf8),
    Array("urn:iso:std:iso:ts:21496".utf8),
    Array("HDRGainMap".utf8),
    Array("hdr_gain_map".utf8),
]

func hasGainMap(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        let bytes = raw.bindMemory(to: UInt8.self)

        // HEIF: the ftyp box lists "tmap" among its brands when a gain map is
        // present. It sits in the first few dozen bytes.
        if bytes.count >= 16,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let size = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16)
                     | (Int(bytes[2]) << 8) | Int(bytes[3])
            var i = 16
            let end = min(size, bytes.count)
            while i + 4 <= end {
                if bytes[i] == 0x74, bytes[i+1] == 0x6D,
                   bytes[i+2] == 0x61, bytes[i+3] == 0x70 { return true }
                i += 4
            }
            return false
        }

        // JPEG: the gain map announces itself in the XMP packet near the front.
        for pattern in gainMapMarkers {
            guard bytes.count >= pattern.count else { continue }
            let first = pattern[0]
            for i in 0...(bytes.count - pattern.count) where bytes[i] == first {
                var match = true
                for j in 1..<pattern.count where bytes[i + j] != pattern[j] {
                    match = false
                    break
                }
                if match { return true }
            }
        }
        return false
    }
}
