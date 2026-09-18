import SwiftUI
import Photos

struct ContentView: View {
    @State private var library = PhotoLibrary()
    @State private var pipeline = Pipeline()
    @State private var showResults = false
    @State private var newAlbumName = ""
    @State private var showClearLogs = false
    @State private var logCount = LogStore.files().count
    @State private var previewItem: PhotoItem?

    var body: some View {
        Group {
            switch library.authStatus {
            case .authorized, .limited: main
            case .notDetermined:        AccessPrompt(library: library)
            default:                    AccessDenied()
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .task {
            if library.authStatus == .authorized || library.authStatus == .limited {
                await library.loadAlbums()
                await library.loadPhotos()
            }
        }
        .sheet(isPresented: $showResults) {
            ResultsSheet(pipeline: pipeline, library: library)
        }
        .onChange(of: showResults) { _, _ in logCount = LogStore.files().count }
        .confirmationDialog(
            "清理 \(logCount) 个日志文件？",
            isPresented: $showClearLogs, titleVisibility: .visible
        ) {
            Button("清理（\(formatBytes(LogStore.totalBytes))）", role: .destructive) {
                LogStore.clear()
                logCount = 0
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除运行日志，不会影响任何照片。日志记录了每张照片转换前后的对应关系，删掉之后就无法再追溯了。")
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AlbumSidebar(library: library)
                Divider()
                PhotoGrid(library: library, previewItem: $previewItem)
                Divider()
                SettingsPanel(library: library, pipeline: pipeline, newAlbumName: $newAlbumName)
            }
            Divider()
            bottomBar
        }
        // Presented from here rather than inside the grid so it covers the
        // whole content area instead of leaving the toolbar strip showing.
        .overlay {
            if let previewItem {
                PreviewOverlay(item: previewItem, library: library) {
                    withAnimation(.easeInOut(duration: 0.18)) { self.previewItem = nil }
                }
                .transition(.opacity)
                .ignoresSafeArea()
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text("原图会一直保留，直到新照片通过校验")
                .font(.callout)
                .foregroundStyle(.secondary)

            Menu {
                Button("打开日志文件夹") { LogStore.reveal() }
                Divider()
                Button("清理日志…", role: .destructive) { showClearLogs = true }
                    .disabled(logCount == 0)
            } label: {
                Label(logCount == 0 ? "日志" : "日志 (\(logCount))",
                      systemImage: "doc.text")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            if pipeline.running {
                ProgressView(value: pipeline.progress)
                    .frame(width: 160)
                Text(pipeline.currentNote)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("取消") { pipeline.cancelled = true }
            } else {
                if library.excludedFromSelection > 0 {
                    Text("已排除 \(library.excludedFromSelection) 张非 JPEG/PNG")
                        .font(.callout).foregroundStyle(.orange)
                }

                Button("转换 \(library.convertibleSelection.count) 张") {
                    Task {
                        await pipeline.run(items: library.convertibleSelection, library: library)
                        library.selectAll(false)   // a finished batch should not stay armed
                        await library.loadAlbums() // counts moved when photos were filed
                        showResults = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(library.convertibleSelection.isEmpty || library.scanning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Access

struct AccessPrompt: View {
    let library: PhotoLibrary
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("需要访问「照片」").font(.title2)
            Text("用于读取 JPEG 原图、写入转换后的 HEIF，以及在你确认后删除原图。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("授权访问") { Task { await library.requestAccess() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AccessDenied: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("没有照片访问权限").font(.title3)
            Text("到「系统设置 → 隐私与安全性 → 照片」里为本 App 打开完全访问权限。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct AlbumSidebar: View {
    let library: PhotoLibrary
    @State private var collapsed: Set<String> = []

    private var list: some View {
        List {
            // Collapsible sections rather than DisclosureGroups: a Section keeps
            // the sidebar's own header styling and row indentation, so every
            // group lines up without hand-tuned padding.
            Section(isExpanded: expansion("图库")) {
                row(.allPhotos, icon: "photo.on.rectangle")
                row(.recentlyAdded, icon: "clock.arrow.circlepath")
                row(.favorites, icon: "heart")
                row(.notInAnyAlbum, icon: "questionmark.folder")
            } header: {
                Text("图库")
            }
            ForEach(library.albumsByKind, id: \.kind.sectionTitle) { group in
                Section(isExpanded: expansion(group.kind.sectionTitle)) {
                    ForEach(group.albums) { a in
                        row(.album(a), icon: a.kind.icon, album: a)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(group.kind.sectionTitle)
                        Text("\(group.albums.count)")
                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // A plain VStack rather than safeAreaInset: the inset escaped the sidebar's
    // width and pushed the whole window layout out of shape.
    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            HStack(spacing: 6) {
                Button {
                    Task {
                        await library.loadAlbums()
                        await library.loadPhotos()
                    }
                } label: {
                    Label("刷新相簿", systemImage: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(library.scanning)

                Spacer(minLength: 0)
                if library.scanning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: 210)
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(key) },
            set: { open in
                if open { collapsed.remove(key) } else { collapsed.insert(key) }
            })
    }

    @ViewBuilder
    private func row(_ scope: LibraryScope, icon: String, album: AlbumRef? = nil) -> some View {
        let isSelected = library.scope == scope
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 16)
            Text(scope.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            // No lock badge here: the section heading already says whether these
            // are shared or synced albums, and the destination panel spells out
            // what happens when one cannot be written to.
            if let a = album {
                Text("\(a.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())          // the whole row is the hit target
        .onTapGesture { library.setScope(scope) }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
    }
}

// MARK: - Grid

/// Reports where each tile sits, so a rubber-band drag can work out what it covers.
struct TileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Plain reference box: tile frames change on every layout pass, and writing
/// them into @State would rebuild the whole grid each time — which starved the
/// tiles of redraws and left them blank.
final class FrameStore {
    var frames: [String: CGRect] = [:]
}

struct PhotoGrid: View {
    let library: PhotoLibrary
    @Binding var previewItem: PhotoItem?

    @State private var frameStore = FrameStore()
    @State private var dragFrom: CGPoint?
    @State private var dragTo: CGPoint?
    @State private var selectionAtDragStart: Set<String> = []
    @State private var lastTapped: String?
    @State private var showDeleteSelected = false
    @State private var deleteError: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    private var hasNoSelection: Bool { library.selectedItems.isEmpty }

    private var scopeKey: String {
        switch library.scope {
        case .allPhotos:     "all"
        case .recentlyAdded: "recent"
        case .favorites:     "favorites"
        case .notInAnyAlbum: "noalbum"
        case .album(let a):  a.id
        }
    }

    private var band: CGRect? {
        guard let a = dragFrom, let b = dragTo else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if library.scanning {
                    ProgressView(value: library.scanProgress).frame(width: 120)
                }
                Text(library.scanNote).font(.callout).foregroundStyle(.secondary)
                Spacer()
                // All three are plain text buttons on purpose: an icon label is
                // taller, and these come and go, so the row would change height
                // and nudge the grid down.
                if !hasNoSelection {
                    // Hidden outright when anything in the selection cannot be
                    // deleted — offering a button that would fail is worse than
                    // not offering one.
                    if library.selectionIsDeletable {
                        Button("删除所选") { showDeleteSelected = true }
                            .tint(.red)
                            .help("直接从图库删除这 \(library.selectedItems.count) 张，不做转换")
                    }
                    Button("全不选") { library.selectAll(false) }
                }
                Button("全选") { Task { await library.selectEverything() } }
                    .disabled(library.items.isEmpty || library.scanning)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .confirmationDialog(
                "删除所选的 \(library.selectedItems.count) 张照片？",
                isPresented: $showDeleteSelected, titleVisibility: .visible
            ) {
                Button("删除（\(formatBytes(library.selectedTotalBytes))）", role: .destructive) {
                    Task {
                        do { try await library.deleteSelected() }
                        catch { deleteError = "删除失败：\(error.localizedDescription)" }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这些照片会直接从图库删除，不会先转换。含 RAW 的照片会连同 RAW 一起删除。删除后进入「最近删除」，30 天内可恢复；macOS 还会再确认一次。")
            }
            .alert("删除失败", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("好") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }

            if library.items.isEmpty && !library.scanning {
                // Without an expanding frame this view only claims its ideal
                // height, and the VStack ends up centred with the toolbar
                // floating in the middle of the pane.
                ContentUnavailableView("没有照片",
                    systemImage: "photo",
                    description: Text("这个相簿里没有照片。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(library.items.enumerated()), id: \.element.id) { index, item in
                            Thumb(item: item, library: library) {
                                tap(index: index, item: item)
                            } onPreview: {
                                library.classify(item)
                                openPreview(item)
                            }
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: TileFramesKey.self,
                                        value: [item.id: g.frame(in: .named("grid"))])
                                })
                        }
                    }
                    .padding(12)
                    .overlay(alignment: .topLeading) {
                        if let r = band {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.15))
                                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .onPreferenceChange(TileFramesKey.self) { frameStore.frames = $0 }
                    .gesture(rubberBand)
                }
                .coordinateSpace(name: "grid")
                .hideScrollEdgeEffect()
                // Focusable only so the space key lands here; the ring it would
                // otherwise draw around the whole grid is pure noise.
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard let id = lastTapped,
                          let item = library.items.first(where: { $0.id == id })
                    else { return .ignored }
                    if previewItem == nil { openPreview(item) } else { closePreview() }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard previewItem != nil else { return .ignored }
                    closePreview()
                    return .handled
                }
                .onKeyPress(.leftArrow) { stepPreview(-1) }
                .onKeyPress(.rightArrow) { stepPreview(1) }
                // A new scope is a new list: rebuilding the subtree sends the
                // scroll position back to the top and gives every tile a fresh
                // onAppear.
                .id(scopeKey)
            }
        }
        .frame(minWidth: 380, maxHeight: .infinity, alignment: .top)
    }

    /// Plain drag adds to the selection; it never clears what you already picked.
    private var rubberBand: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("grid"))
            .onChanged { v in
                if dragFrom == nil {
                    dragFrom = v.startLocation
                    selectionAtDragStart = Set(library.items.filter(\.selected).map(\.id))
                }
                dragTo = v.location
                guard let r = band else { return }
                for item in library.items {
                    guard let f = frameStore.frames[item.id] else { continue }
                    if f.intersects(r) {
                        library.classify(item)
                        item.selected = true
                    } else {
                        item.selected = selectionAtDragStart.contains(item.id)
                    }
                }
            }
            .onEnded { _ in
                dragFrom = nil
                dragTo = nil
                selectionAtDragStart = []
            }
    }

    private var previewFade: Animation { .easeInOut(duration: 0.18) }

    private func openPreview(_ item: PhotoItem) {
        withAnimation(previewFade) { previewItem = item }
    }

    private func closePreview() {
        withAnimation(previewFade) { previewItem = nil }
    }

    /// Arrow keys walk the grid while the preview is open, and are left alone
    /// otherwise so they still scroll the list.
    private func stepPreview(_ delta: Int) -> KeyPress.Result {
        guard let current = previewItem,
              let i = library.items.firstIndex(where: { $0.id == current.id })
        else { return .ignored }
        let j = i + delta
        guard library.items.indices.contains(j) else { return .handled }
        let next = library.items[j]
        library.classify(next)
        previewItem = next   // no animation: paging should feel immediate
        lastTapped = next.id
        return .handled
    }

    private func tap(index: Int, item: PhotoItem) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let anchorID = lastTapped,
           let anchor = library.items.firstIndex(where: { $0.id == anchorID }) {
            let range = anchor <= index ? anchor...index : index...anchor
            for i in range {
                library.classify(library.items[i])
                library.items[i].selected = true
            }
        } else {
            library.classify(item)
            item.selected.toggle()
        }
        lastTapped = item.id
    }
}

struct Thumb: View {
    let item: PhotoItem
    let library: PhotoLibrary
    var onTap: () -> Void
    var onPreview: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let img = item.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // A white hairline inside the blue keeps the ring readable against
            // photos that are themselves blue or dark.
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                    RoundedRectangle(cornerRadius: 8)
                        .inset(by: 3)
                        .strokeBorder(.white, lineWidth: 1)
                }
                .opacity(item.selected ? 1 : 0))
            .animation(.easeOut(duration: 0.1), value: item.selected)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(item.badges, id: \.self) { b in
                    Text(b).font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.thinMaterial, in: Capsule())
                }
            }
            .padding(4)

            if item.selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .padding(3)
                    .frame(width: 96, height: 96, alignment: .topTrailing)
            }

            if item.asset.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
                    .padding(5)
                    .frame(width: 96, height: 96, alignment: .bottomLeading)
            }

            if item.state != .pending {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                    .padding(4)
                    .frame(width: 96, height: 96, alignment: .bottomTrailing)
            }
        }
        .contentShape(Rectangle())
        // No double-click preview: pairing it with the single-click selection
        // makes SwiftUI hold every click for the double-click timeout, which
        // showed up as a visible delay before a tile highlighted.
        .onTapGesture { onTap() }
        .contextMenu {
            Button("预览") { onPreview() }
            Button("在「照片」中显示") { revealInPhotos(item.asset) }
        }
        .onAppear { library.loadThumbnail(for: item) }
        .help(item.errorText ?? "")
    }

    private var stateIcon: String {
        switch item.state {
        case .working:  "circle.dotted"
        case .verified: "checkmark.circle.fill"
        case .failed:   "exclamationmark.triangle.fill"
        case .skipped:  "minus.circle.fill"
        case .deleted:  "trash.circle.fill"
        case .pending:  ""
        }
    }
    private var stateColor: Color {
        switch item.state {
        case .verified: .green
        case .failed:   .orange
        case .deleted:  .secondary
        default:        .secondary
        }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    let library: PhotoLibrary
    @Bindable var pipeline: Pipeline
    @Binding var newAlbumName: String
    @FocusState private var editingLongEdge: Bool
    @State private var longEdgeText = "6000"

    var body: some View {
        Form {
            Section("保存到") {
                Picker("", selection: destinationTag) {
                    Text("原相簿").tag(0)
                    Text("选择相簿").tag(1)
                    Text("新建相簿").tag(2)
                    Text("仅图库").tag(3)
                }
                .pickerStyle(.radioGroup).labelsHidden()

                if destinationTag.wrappedValue == 1 {
                    Picker("相簿", selection: albumSelection) {
                        ForEach(library.albums.filter(\.canAddContent)) { a in
                            Text(a.title).tag(a.id as String?)
                        }
                    }
                }
                if destinationTag.wrappedValue == 2 {
                    TextField("相簿名称", text: $newAlbumName)
                        .onChange(of: newAlbumName) { _, v in pipeline.destination = .newAlbum(v) }
                }
                if let notice = destinationNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("转换") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("质量")
                        Spacer()
                        Text("\(qualityPercent)").monospacedDigit()
                    }
                    Slider(value: $pipeline.quality, in: 0.5...1.0, step: 0.05)
                }
                if qualityPercent > 90 {
                    // Measured on a real 24MP photo: 90% saves ~6%, 95% and
                    // above produce a HEIC larger than the source JPEG.
                    Label("90% 以上收益极低，95% 起会比原图更大",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("转换后不小于原图就跳过", isOn: $pipeline.skipIfNotSmaller)

                Toggle("优化尺寸", isOn: $pipeline.optimizeSize)
                HStack {
                    Text("长边上限").font(.callout)
                    Spacer()
                    TextField("", text: $longEdgeText)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .focused($editingLongEdge)
                        .onChange(of: longEdgeText) { _, new in
                            // Digits only, and no thousands separator: this is a
                            // pixel count, not a formatted number.
                            let digits = String(new.filter(\.isNumber).prefix(5))
                            if digits != new { longEdgeText = digits }
                            if let v = Int(digits) { pipeline.maxLongEdge = v }
                        }
                        .onSubmit { commitLongEdge() }
                        .onChange(of: editingLongEdge) { _, focused in
                            if !focused { commitLongEdge() }
                        }
                    Text("px").font(.callout).foregroundStyle(.secondary)
                }
                // Always present, just disabled. Pulling a focused text field
                // out of the hierarchy can leave its focus ring behind.
                .disabled(!pipeline.optimizeSize)
                .opacity(pipeline.optimizeSize ? 1 : 0.4)
                .onChange(of: pipeline.optimizeSize) { _, on in
                    if !on { editingLongEdge = false; commitLongEdge() }
                }
                if pipeline.optimizeSize {
                    Text("长边超过这个值的照片会等比缩小到这个值，没超过的保持原尺寸。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("预估") {
                LabeledContent("可转换", value: "\(library.convertibleSelection.count) 张")
                LabeledContent("原始体积",
                               value: library.selectedBytes > 0
                                   ? formatBytes(library.selectedBytes) : "—")
                LabeledContent("预计节省", value: savingText)
                if pipeline.optimizeSize {
                    LabeledContent("优化尺寸", value: "\(oversizedCount) 张")
                }
                Text("按所选质量的实测区间估算，已计入尺寸优化。HDR 照片压缩率通常低于 SDR，区间两端大致对应这两种情况。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .hideScrollEdgeEffect()
        .frame(width: 260)
        .onAppear { longEdgeText = String(pipeline.maxLongEdge) }
    }

    private var qualityPercent: Int { Int((pipeline.quality * 100).rounded()) }

    private var oversizedCount: Int {
        library.convertibleSelection.filter { $0.longEdge > pipeline.maxLongEdge }.count
    }

    /// Applies the bounds and writes the cleaned value back to the field, so an
    /// out-of-range entry does not silently stay on screen.
    private func commitLongEdge() {
        let v = min(max(Int(longEdgeText) ?? pipeline.maxLongEdge, 512), 20000)
        pipeline.maxLongEdge = v
        longEdgeText = String(v)
    }

    private var savingText: String {
        let bytes = library.selectedBytes
        guard bytes > 0 else { return "—" }
        let items = library.convertibleSelection.map { (bytes: $0.originalBytes, longEdge: $0.longEdge) }
        let (lo, hi) = SizeEstimate.savedRange(
            items: items, quality: pipeline.quality,
            maxLongEdge: pipeline.optimizeSize ? pipeline.maxLongEdge : nil)
        if hi <= 0 {
            return "会变大 " + formatBytes(-hi) + " ~ " + formatBytes(-lo)
        }
        if lo <= 0 {
            return "最多 " + formatBytes(hi)
        }
        return formatBytes(lo) + " ~ " + formatBytes(hi)
    }

    /// Spells out where photos will actually land when "same album" cannot be
    /// honoured — a shared album accepts no writes, so the copy would quietly
    /// end up in the library only.
    private var destinationNotice: String? {
        guard destinationTag.wrappedValue == 0 else { return nil }

        if case .album(let a) = library.scope, !a.canAddContent {
            let what = a.kind == .shared ? "共享相簿" : "只读相簿"
            return "「\(a.title)」是\(what)，无法写入。转换后的照片只会进入图库，不会出现在这个相簿里。"
        }
        if lockedCount > 0 {
            return "有 \(lockedCount) 张照片的原相簿不可写入，它们只会进入图库。"
        }
        return nil
    }

    private var lockedCount: Int {
        library.convertibleSelection.filter { item in
            let c = PHAssetCollection.fetchAssetCollectionsContaining(item.asset, with: .album, options: nil)
            var writable = false
            var any = false
            c.enumerateObjects { col, _, _ in
                any = true
                if col.canPerform(.addContent) { writable = true }
            }
            return any && !writable
        }.count
    }

    private var destinationTag: Binding<Int> {
        Binding(
            get: {
                switch pipeline.destination {
                case .sameAsOriginal: 0
                case .album:          1
                case .newAlbum:       2
                case .libraryOnly:    3
                }
            },
            set: { tag in
                switch tag {
                case 0: pipeline.destination = .sameAsOriginal
                case 1: pipeline.destination = library.albums.first(where: \.canAddContent)
                            .map { Destination.album($0) } ?? .libraryOnly
                case 2: pipeline.destination = .newAlbum(newAlbumName.isEmpty ? "HEIF 转换" : newAlbumName)
                default: pipeline.destination = .libraryOnly
                }
            })
    }

    private var albumSelection: Binding<String?> {
        Binding(
            get: { if case .album(let a) = pipeline.destination { a.id } else { nil } },
            set: { id in
                if let a = library.albums.first(where: { $0.id == id }) {
                    pipeline.destination = .album(a)
                }
            })
    }
}


extension View {
    /// macOS 26 draws a hairline at a scroll view's edge when the window state
    /// changes — presenting a sheet is enough to make it flash across the top
    /// of the settings pane.
    @ViewBuilder
    func hideScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}


/// Photos.app registers a "photos" URL scheme, but the form that selects a
/// single asset is undocumented, so this is best effort: the app opens either
/// way, it may just not jump to the photo.
func revealInPhotos(_ asset: PHAsset) {
    let uuid = asset.localIdentifier.components(separatedBy: "/").first ?? asset.localIdentifier
    let candidates = [
        "photos://asset?uuid=\(uuid)",
        "photos-navigation://asset?uuid=\(uuid)",
        "photos://",
    ]
    for s in candidates {
        if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
    }
}
