import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import Photos
import UIKit

enum NativePreviewContent {
    case image(UIImage)
    case text(String, truncated: Bool)

    static func read(_ url: URL) throws -> NativePreviewContent? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
           ] as CFDictionary) { return .image(UIImage(cgImage: image)) }
        let type = UTType(filenameExtension: url.pathExtension)
        let textType = type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true
            || type?.conforms(to: .json) == true || type?.conforms(to: .xml) == true
        // Known archives/documents stay with the system even if their sample
        // content happens to decode as UTF-8. Unknown extensions allow text sniffing.
        if let type, !textType, !type.isDynamic { return nil }
        let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
        let limit = 2 * 1024 * 1024
        let bytes = try stream.read(upToCount: limit + 4) ?? Data()
        var text: String?
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
            text = String(data: bytes.prefix(bytes.count - bytes.count % 2), encoding: .utf16)
        } else if !bytes.contains(0) {
            // A truncated UTF-8 character at the end must not turn text into binary.
            for extra in 0...min(3, bytes.count) {
                if let decoded = String(data: bytes.dropLast(extra), encoding: .utf8) { text = decoded; break }
            }
        }
        guard let text else { return nil }
        return .text(text, truncated: bytes.count > limit)
    }
}

/// Owns the downloaded temporary folder for the entire preview/share lifetime.
final class NativePreviewFile: Identifiable {
    let url: URL
    let content: NativePreviewContent
    var id: String { url.path }
    init(url: URL, content: NativePreviewContent) { self.url = url; self.content = content }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct NativeFilePreview: View {
    let file: NativePreviewFile
    @Environment(\.dismiss) private var dismiss
    @State private var external = false
    @State private var saving = false
    @State private var notice = ""
    @State private var error = ""
    @State private var renderMarkdown = true
    @AppStorage("native.previewLineWrapping") private var wrapsLines = true
    private var isMarkdown: Bool { NativeCodeLanguages.name(file.url.lastPathComponent) == "markdown" }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).padding(10) }
                content
            }
            .navigationTitle(file.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if case .image = file.content {
                            Button("保存到相册", systemImage: "square.and.arrow.down") { Task { await saveImage() } }.disabled(saving)
                        }
                        Button("系统文件打开", systemImage: "arrow.up.forward.square") { external = true }
                        if case .text = file.content {
                            Toggle("自动换行", isOn: $wrapsLines)
                            if isMarkdown { Toggle("渲染 Markdown", isOn: $renderMarkdown) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
                        .accessibilityLabel("预览文件选项").accessibilityIdentifier("native.file.preview.menu")
                }
            }
            .sheet(isPresented: $external) { ShareView(file: file.url, cleanupOnDismiss: false) }
            .alert("操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error) }
        }.interactiveDismissDisabled(saving)
    }
    @ViewBuilder private var content: some View {
        switch file.content {
        case .image(let image):
            NativePreviewImage(image: image).accessibilityIdentifier("native.file.preview.image")
        case .text(let text, let truncated):
            VStack(spacing: 0) {
                if truncated { Text("仅预览前 2 MiB，系统文件打开可查看完整文件。").font(.caption).foregroundStyle(.secondary).padding(10) }
                if isMarkdown && renderMarkdown {
                    ScrollView { NativeChatMarkdown(text: text).padding(16) }.accessibilityIdentifier("native.file.preview.markdown")
                } else {
                    NativeCodeView(text: .constant(text), language: file.url.lastPathComponent, wrapsLines: wrapsLines, identifier: "native.file.preview.text")
                }
            }
        }
    }
    @MainActor private func saveImage() async {
        saving = true; defer { saving = false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            error = "请在系统设置中允许 codex-link 添加照片到相册。"; return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file.url)
            }
            notice = "已保存到相册"
        } catch { self.error = error.localizedDescription }
    }
}

/// UIKit keeps image zooming independent of the transcript's scroll gestures.
private struct NativePreviewImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = PreviewScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator; scroll.backgroundColor = .systemBackground
        let view = UIImageView(image: image); view.contentMode = .scaleAspectFit
        scroll.addSubview(view); scroll.imageView = view; context.coordinator.imageView = view
        view.isAccessibilityElement = true; view.accessibilityLabel = "图片预览，可双指缩放"
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
    final class PreviewScrollView: UIScrollView {
        weak var imageView: UIImageView?
        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { imageView?.frame = bounds; contentSize = bounds.size }
        }
    }
}
