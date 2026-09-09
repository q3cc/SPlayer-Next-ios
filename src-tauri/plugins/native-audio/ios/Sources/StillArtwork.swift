import AVFoundation
import MediaPlayer
import UIKit

/// 系统按需请求时才编码两帧相同的封面，不运行动画定时器或播放额外音轨。
final class StillArtworkAsset: @unchecked Sendable {
  let preview: UIImage
  private let fileURL: URL
  private let lock = NSLock()
  private var operation: Task<URL?, Never>?

  init(image: UIImage, size: CGSize) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      let scale = max(size.width / image.size.width, size.height / image.size.height)
      let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      image.draw(in: CGRect(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2,
        width: scaled.width, height: scaled.height))
    }
    fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("splayer-still-\(UUID().uuidString).mp4")
  }

  deinit {
    let pending = operation
    let url = fileURL
    // 编码结束后再删除，避免切歌时留下迟到的视频文件。
    Task {
      _ = await pending?.value
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func videoTask() -> Task<URL?, Never> {
    lock.lock()
    defer { lock.unlock() }
    if let operation = operation { return operation }
    let image = preview
    let url = fileURL
    let task = Task.detached(priority: .utility) {
      do {
        try await Self.encode(image: image, to: url)
        NSLog("[now-playing-artwork] video-ready %.0fx%.0f", image.size.width, image.size.height)
        return Optional(url)
      } catch {
        NSLog("[now-playing-artwork] encode-failed %@", error.localizedDescription)
        try? FileManager.default.removeItem(at: url)
        return nil
      }
    }
    operation = task
    return task
  }

  func videoURL() async -> URL? { await videoTask().value }

  private static func encode(image: UIImage, to url: URL) async throws {
    let width = Int(image.size.width), height = Int(image.size.height)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width, AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoExpectedSourceFrameRateKey: 1]
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ])
    guard writer.canAdd(input) else { throw failure("无法创建封面视频轨道") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? failure("无法开始封面编码") }
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool,
          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
          let pixelBuffer = buffer, let cgImage = image.cgImage else {
      writer.cancelWriting(); throw failure("无法分配封面画面")
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    guard let context = context else {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, []); writer.cancelWriting(); throw failure("无法绘制封面画面")
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      var frame = 0
      var finished = false
      input.requestMediaDataWhenReady(on: DispatchQueue(label: "splayer.still-artwork")) {
        guard !finished else { return }
        while input.isReadyForMoreMediaData && frame < 2 {
          guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)) else {
            finished = true
            let error = writer.error ?? failure("封面画面写入失败")
            writer.cancelWriting(); continuation.resume(throwing: error); return
          }
          frame += 1
        }
        if frame == 2 {
          finished = true
          input.markAsFinished()
          writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
          writer.finishWriting {
            if writer.status == .completed { continuation.resume() }
            else { continuation.resume(throwing: writer.error ?? failure("封面视频未完成")) }
          }
        }
      }
    }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "SPlayer.StillArtwork", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

@available(iOS 26.0, *)
enum StillArtwork {
  static func clear(from info: inout [String: Any]) {
    info.removeValue(forKey: MPNowPlayingInfoProperty1x1AnimatedArtwork)
    info.removeValue(forKey: MPNowPlayingInfoProperty3x4AnimatedArtwork)
  }

  static func install(image: UIImage, id: String, into info: inout [String: Any]) {
    clear(from: &info)
    for (key, size) in [
      (MPNowPlayingInfoProperty1x1AnimatedArtwork, CGSize(width: 1024, height: 1024)),
      (MPNowPlayingInfoProperty3x4AnimatedArtwork, CGSize(width: 768, height: 1024))
    ] where MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.contains(key) {
      let asset = StillArtworkAsset(image: image, size: size)
      info[key] = MPMediaItemAnimatedArtwork(
        artworkID: id + ":" + key,
        previewImageRequestHandler: { _ in asset.preview },
        videoAssetFileURLRequestHandler: { _ in await asset.videoURL() }
      )
    }
  }
}
