import SwiftUI
import Photos

/// A large in-app preview. Quick Look would need the asset exported to a file
/// first; rendering through PHImageManager avoids that round trip entirely.
struct PreviewOverlay: View {
    let item: PhotoItem
    let library: PhotoLibrary
    var onClose: () -> Void

    @State private var image: NSImage?
    @State private var shownID: String?
    @State private var hdrCapable = ScreenHDR.currentlyAvailable()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.88))
                .ignoresSafeArea()

            if let image {
                // NSImageView rather than SwiftUI's Image: only AppKit exposes
                // preferredImageDynamicRange, which is what lets the highlights
                // above white actually render on an EDR display.
                HDRImageView(image: image, allowHDR: hdrCapable)
                    .id(shownID ?? item.id)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .padding(9)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                }
                Spacer()
                Text(caption)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 18)
                    .animation(nil, value: item.id)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        // The previous frame stays up until the next one decodes, so stepping
        // through photos never flashes an empty pane. No animation here: the
        // fade belongs to opening and closing the overlay, not to paging.
        .task(id: item.id) { load() }
        // The window can be dragged onto a display with different capabilities,
        // and a display's own headroom can change underneath it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didChangeScreenNotification)) { _ in refreshCapability() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in refreshCapability() }
    }

    private func load() {
        let target = item.id
        let wantsHDR = hdrCapable
        library.loadPreview(for: item, side: 1600, hdr: wantsHDR) { img in
            guard target == item.id, let img else { return }
            image = img
            shownID = target
        }
    }

    private func refreshCapability() {
        let now = ScreenHDR.currentlyAvailable()
        guard now != hdrCapable else { return }
        hdrCapable = now
        load()
    }

    private var caption: String {
        var parts: [String] = []
        if let name = item.originalFilename { parts.append(name) }
        parts.append("\(item.pixelWidth) × \(item.pixelHeight)")
        if item.originalBytes > 0 { parts.append(formatBytes(item.originalBytes)) }
        if item.isHDR { parts.append("HDR") }
        return parts.joined(separator: "   ")
    }
}


enum ScreenHDR {
    /// Potential rather than current headroom: the current value sits at 1.0 on
    /// a capable display until something HDR is actually on screen.
    static func currentlyAvailable() -> Bool {
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let screen else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }
}

/// Displays an image, allowing extended dynamic range only where the display
/// can show it.
struct HDRImageView: NSViewRepresentable {
    let image: NSImage
    let allowHDR: Bool

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.preferredImageDynamicRange = allowHDR ? .high : .standard
        v.animates = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        v.image = image
        v.preferredImageDynamicRange = allowHDR ? .high : .standard
    }
}
