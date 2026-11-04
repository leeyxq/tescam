import AVFoundation
import ImageIO
import SwiftUI
import TeslaCamKit

/// 优先使用事件目录中的 thumb.png，否则从前视视频截取首帧。
struct ThumbnailView: View {
    let event: DashcamEvent
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: event.kind.symbolName).foregroundStyle(.secondary)
            }
        }
        .task(id: event.id) { image = await ThumbnailCache.shared.thumbnail(for: event) }
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: CGImage] = [:]

    func thumbnail(for event: DashcamEvent) async -> CGImage? {
        if let cached = cache[event.id] { return cached }
        var image: CGImage?
        if let url = event.thumbnailURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let segment = event.segments[0]
        if image == nil, let url = segment.files[.front] ?? segment.cameras.first.flatMap({ segment.files[$0] }) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: 320, height: 240)
            image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        }
        cache[event.id] = image
        return image
    }
}
