import Foundation
import Observation
import Photos
import AppKit

/// One JPEG in the library that is a candidate for conversion.
@Observable
final class PhotoItem: Identifiable {
    let id: String
    let asset: PHAsset
    var originalBytes: Int
    var isLivePhoto: Bool
    var isEdited: Bool
    /// A RAW file is paired with this asset. Converting is still allowed, but
    /// deleting the original takes the RAW with it — they are one asset.
    var hasRAW = false
    /// Assets in an iCloud shared album, and other library-managed ones, refuse
    /// deletion. Asking PhotoKit is more reliable than guessing from the album.
    var isDeletable = true
    /// Carried over so the converted copy keeps the name, with a .heic suffix.
    var originalFilename: String?
    var isHDR = false
    var hdrProbed = false

    var pixelWidth: Int { asset.pixelWidth }
    var pixelHeight: Int { asset.pixelHeight }
    var longEdge: Int { max(asset.pixelWidth, asset.pixelHeight) }
    var thumbnail: NSImage?
    /// Guards against firing a second request while one is still in flight.
    var thumbLoading = false
    var selected: Bool = false
    var kind: Kind = .unknown

    /// What the asset's original resource actually is. Decided from the
    /// resource list, which is cheap — no file is read.
    enum Kind: Equatable {
        case unknown
        case jpeg
        case png
        case animated           // GIF and friends: converting keeps one frame
        case other(String)      // HEIC, TIFF, anything else

        var isConvertible: Bool { self == .jpeg || self == .png }

        var badge: String? {
            switch self {
            case .unknown:      nil
            case .jpeg:         "JPEG"
            case .png:          "PNG"
            case .animated:     "动图"
            case .other(let u): shortName(u)
            }
        }
    }

    /// Filled in once the photo has been through the pipeline.
    var outcome: ConversionOutcome?
    var errorText: String?
    var newAssetID: String?
    var state: State = .pending

    enum State: Equatable {
        case pending, working, verified, failed, skipped, deleted
    }

    init(asset: PHAsset, originalBytes: Int = 0, isLivePhoto: Bool = false, isEdited: Bool = false) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.originalBytes = originalBytes
        self.isLivePhoto = isLivePhoto
        self.isEdited = isEdited
    }

    var badges: [String] {
        // Format always leads, so the first line stays aligned across tiles
        // whether or not the photo is HDR.
        var b: [String] = []
        if hasRAW {
            switch kind {
            case .jpeg: b.append("JPEG+RAW")
            case .png:  b.append("PNG+RAW")
            default:    if let k = kind.badge { b.append(k) }; b.append("RAW")
            }
        } else if let k = kind.badge {
            b.append(k)
        }
        if isHDR || outcome?.before.isHDR == true { b.append("HDR") }
        if isLivePhoto { b.append("实况") }
        return b
    }
}

/// What an album actually is. Kept separate from whether it can be written to —
/// those are two different facts and deserve two different bits of UI.
enum AlbumKind {
    case regular        // an ordinary album you made
    case shared         // iCloud shared album
    case synced         // pushed over from Finder, read-only
    case photoStream
    case imported
    case other

    var icon: String {
        switch self {
        case .regular:     "folder"
        case .shared:      "person.2"
        case .synced:      "desktopcomputer"
        case .photoStream: "bolt.horizontal"
        case .imported:    "square.and.arrow.down"
        case .other:       "folder"
        }
    }

    var sectionTitle: String {
        switch self {
        case .regular:     "相簿"
        case .shared:      "共享相簿"
        case .synced:      "同步的相簿"
        case .photoStream: "我的照片流"
        case .imported:    "导入项目"
        case .other:       "其他"
        }
    }

    static func from(_ subtype: PHAssetCollectionSubtype) -> AlbumKind {
        switch subtype {
        case .albumRegular:     .regular
        case .albumCloudShared: .shared
        case .albumSyncedAlbum, .albumSyncedEvent, .albumSyncedFaces: .synced
        case .albumMyPhotoStream: .photoStream
        case .albumImported:    .imported
        default:                .other
        }
    }
}

struct AlbumRef: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let canAddContent: Bool
    let kind: AlbumKind
    let collection: PHAssetCollection

    static func == (a: AlbumRef, b: AlbumRef) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// What the grid is showing.
enum LibraryScope: Equatable {
    case allPhotos       // newest capture first
    case recentlyAdded   // ordered by when each asset entered the library
    case favorites
    case notInAnyAlbum
    case album(AlbumRef)

    var title: String {
        switch self {
        case .allPhotos:     "所有照片"
        case .recentlyAdded: "最近添加"
        case .favorites:     "个人收藏"
        case .notInAnyAlbum: "不在相簿中"
        case .album(let a):  a.title
        }
    }
}

/// Where converted photos get filed.
enum Destination: Equatable {
    case sameAsOriginal
    case album(AlbumRef)
    case newAlbum(String)
    case libraryOnly

    var label: String {
        switch self {
        case .sameAsOriginal: "原相簿"
        case .album(let a): a.title
        case .newAlbum(let n): "新建「\(n)」"
        case .libraryOnly: "仅图库"
        }
    }
}

struct RunSummary {
    var converted = 0
    var skipped = 0
    var failed = 0
    var savedBytes = 0
    var hdrPreserved = 0
    /// Converted fine, but PhotoKit will not let the original be removed.
    var notDeletable = 0
}

func shortName(_ uti: String) -> String {
    switch uti {
    case "public.heic", "public.heif": "HEIF"
    case "public.png":  "PNG"
    case "public.tiff": "TIFF"
    case "public.jpeg": "JPEG"
    case "public.avif": "AVIF"
    case "public.jpeg-xl": "JXL"
    case "com.compuserve.gif": "GIF"
    default: uti.split(separator: ".").last.map(String.init)?.uppercased() ?? uti
    }
}
