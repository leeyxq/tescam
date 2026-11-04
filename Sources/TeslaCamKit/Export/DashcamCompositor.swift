import AVFoundation
import CoreImage

/// 携带布局与叠加层信息的合成指令。
final class DashcamInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let plan: LayoutPlan
    let trackIDs: [Camera: CMPersistentTrackID]
    let overlay: OverlayRenderer

    init(timeRange: CMTimeRange, plan: LayoutPlan, trackIDs: [Camera: CMPersistentTrackID], overlay: OverlayRenderer) {
        self.timeRange = timeRange
        self.plan = plan
        self.trackIDs = trackIDs
        self.overlay = overlay
        self.requiredSourceTrackIDs = trackIDs.values.map { NSNumber(value: $0) }
    }
}

/// 自定义视频合成器：把多路摄像头按布局拼接，并叠加时间戳与车辆数据水印。
/// 预览（AVPlayer）与导出（AVAssetExportSession）共用，保证所见即所得。
final class DashcamCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tescam.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var cancelled = false

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if cancelled {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool { render(request) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async { [self] in cancelled = false }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? DashcamInstruction,
              let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(domain: "TesCam", code: -1,
                                         userInfo: [NSLocalizedDescriptionKey: "无效的合成指令"]))
            return
        }
        let plan = instruction.plan
        let canvas = CGRect(origin: .zero, size: plan.canvasSize)
        var image = CIImage(color: .black).cropped(to: canvas)

        for cell in plan.cells {
            guard let trackID = instruction.trackIDs[cell.camera],
                  let buffer = request.sourceFrame(byTrackID: trackID) else { continue }
            let source = CIImage(cvPixelBuffer: buffer)
            let target = CGRect(x: cell.rect.minX, y: plan.canvasSize.height - cell.rect.maxY,
                                width: cell.rect.width, height: cell.rect.height)
            let scale = min(target.width / source.extent.width, target.height / source.extent.height)
            let width = source.extent.width * scale, height = source.extent.height * scale
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: target.midX - width / 2, y: target.midY - height / 2))
            image = source.transformed(by: transform).cropped(to: target).composited(over: image)
        }

        if let overlay = instruction.overlay.overlay(atSeconds: request.compositionTime.seconds) {
            image = overlay.composited(over: image)
        }
        context.render(image, to: output, bounds: canvas, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}
