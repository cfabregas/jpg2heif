import SwiftUI

struct ResultsSheet: View {
    @Bindable var pipeline: Pipeline
    let library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    // Pre-ticked: everything on this list already passed verification, and the
    // delete still goes through the button, then macOS's own confirmation, then
    // 30 days in Recently Deleted.
    @State private var confirmDelete = true
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            deleteSection
        }
        .frame(width: 620, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("转换完成").font(.title2)
            HStack(spacing: 22) {
                stat("已转换", "\(pipeline.summary.converted)", .green)
                stat("跳过", "\(pipeline.summary.skipped)", .secondary)
                stat("失败", "\(pipeline.summary.failed)",
                     pipeline.summary.failed > 0 ? .orange : .secondary)
                stat("节省", formatBytes(pipeline.summary.savedBytes), .primary)
                stat("HDR 保留", "\(pipeline.summary.hdrPreserved)", .primary)
            }
        }
        .padding(16)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit().foregroundStyle(color)
        }
    }

    private var list: some View {
        List {
            ForEach(pipeline.processed) { item in
                HStack(spacing: 10) {
                    Image(systemName: icon(item)).foregroundStyle(color(item)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.asset.creationDate.map {
                            $0.formatted(date: .abbreviated, time: .shortened)
                        } ?? item.id).font(.callout)
                        if let e = item.errorText {
                            Text(e).font(.caption).foregroundStyle(.orange)
                        } else if let o = item.outcome {
                            Text("\(formatBytes(o.before.fileBytes)) → \(formatBytes(o.after.fileBytes))"
                                 + (o.before.isHDR ? " · HDR 已保留" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func icon(_ i: PhotoItem) -> String {
        switch i.state {
        case .verified: "checkmark.circle.fill"
        case .failed:   "exclamationmark.triangle.fill"
        case .skipped:  "minus.circle"
        case .deleted:  "trash"
        default:        "circle"
        }
    }
    private func color(_ i: PhotoItem) -> Color {
        switch i.state {
        case .verified: .green
        case .failed:   .orange
        case .deleted:  .secondary
        default:        .secondary
        }
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pipeline.deletable.isEmpty {
                if pipeline.summary.notDeletable > 0 {
                    Label("这 \(pipeline.summary.notDeletable) 张的原图无法删除（共享相簿等图库不允许删除的照片）。转换后的副本已存入图库。",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("没有可删除的原图", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Toggle(isOn: $confirmDelete) {
                    Text("删除这 \(pipeline.deletable.count) 张已通过校验的原始 JPEG")
                }
                Text("只有成功转换、尺寸一致、HDR 与元数据均已确认保留的照片才在此列。删除后进入「最近删除」，30 天内可恢复；macOS 还会再确认一次。")
                    .font(.caption).foregroundStyle(.secondary)
                if pipeline.summary.notDeletable > 0 {
                    Text("另有 \(pipeline.summary.notDeletable) 张的原图无法删除，已排除在外。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if let e = deleteError {
                Text(e).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if let url = pipeline.logURL {
                    Button("显示日志") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("关闭") { dismiss() }
                Button(deleting ? "删除中…" : "删除原图") {
                    deleting = true
                    Task {
                        do {
                            try await pipeline.deleteOriginals(pipeline.deletable)
                            // The grid and the sidebar counts are both stale now.
                            await library.loadAlbums()
                            await library.loadPhotos()
                            deleting = false
                            dismiss()
                        } catch {
                            deleteError = "删除失败：\(error.localizedDescription)"
                            deleting = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!confirmDelete || pipeline.deletable.isEmpty || deleting)
            }
        }
        .padding(16)
    }
}
