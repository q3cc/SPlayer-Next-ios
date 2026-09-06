import AVFoundation
import AVKit
import Darwin
import Tauri
import UIKit
import ImageIO

private struct LyricContent: Decodable {
  let title: String
  let artist: String
  let lines: [LyricRow]
  let offset: Double
  let cover: String
  let style: LyricStyle
}

struct LyricColor: Decodable, Equatable {
  let r: Double
  let g: Double
  let b: Double
  let a: Double
  var uiColor: UIColor { UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
}

struct LyricStyle: Decodable, Equatable {
  let fontSize: Double
  let playedColor: LyricColor
  let unplayedColor: LyricColor
}

private struct PreviewRequest: Decodable {
  let content: LyricContent
  let position: Double
  let playing: Bool
}

private struct KeepAwakeRequest: Decodable {
  let enabled: Bool
}

/// 显示层作为视图主图层，随窗口尺寸变化同步布局。
private class LyricVideoView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

private struct PlaybackAnchor: Decodable {
  let position: Double
  let duration: Double
  let playing: Bool
  let speed: Double
  let timestamp: Double
}

@available(iOS 15.0, *)
class LyricPipPlugin: Plugin, AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate {
  private var displayLayer = AVSampleBufferDisplayLayer()
  private var sourceView: UIView?
  private var controller: AVPictureInPictureController?
  private var readiness: NSKeyValueObservation?
  private var suspension: NSKeyValueObservation?
  private var startTimeout: DispatchWorkItem?
  private var pendingStart: Invoke?
  private var timer: Timer?
  private var content: LyricContent?
  private var position = 0.0
  private var duration = 0.0
  private var playing = false
  private var speed = 1.0
  private var anchorTime = ProcessInfo.processInfo.systemUptime
  private var lastText: [String]?
  private var lastPrimary = -1
  private var lastLyricTime = -Double.infinity
  private var cachedFrame: CVPixelBuffer?
  private var lastFrameTime = -Double.infinity
  private var frameCount = 0
  private var lastRenderError: String?
  private var coverURL = ""
  private var coverTask: URLSessionDataTask?
  private var coverImage: UIImage?
  private var discAngle = 0.0
  private var discAnchorTime = ProcessInfo.processInfo.systemUptime
  private let lyricRenderer = PipLyricRenderer()
  private let previewRenderer = PipLyricRenderer()

  private var displayReadiness: String {
    if #available(iOS 17.4, *) { return String(displayLayer.isReadyForDisplay) }
    return "unavailable-before-ios-17.4"
  }

  @objc public func status(_ invoke: Invoke) {
    invoke.resolve(["active": controller?.isPictureInPictureActive ?? false])
  }

  @objc public func keepawake(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(KeepAwakeRequest.self)
    DispatchQueue.main.async {
      UIApplication.shared.isIdleTimerDisabled = request.enabled
      invoke.resolve()
    }
  }

  @objc public func update(_ invoke: Invoke) throws {
    let next = try invoke.parseArgs(LyricContent.self)
    DispatchQueue.main.async {
      self.applyContent(next)
      self.render()
      self.updateTimer()
      invoke.resolve()
    }
  }

  private func applyContent(_ next: LyricContent) {
      self.lastText = nil
      self.content = next
      if self.coverURL != next.cover {
        self.coverTask?.cancel()
        self.coverTask = nil
        self.coverURL = next.cover
        self.coverImage = nil
        self.lastText = nil
        if let url = URL(string: next.cover), ["https", "http"].contains(url.scheme ?? "") {
          self.coverTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            // 只解码唱片缩略图，不在小窗保留原始大封面。
            let image = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap {
              CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 112
              ] as CFDictionary)
            }
            DispatchQueue.main.async {
              guard let self = self, self.coverURL == next.cover else { return }
              self.coverTask = nil
              self.coverImage = image.map { UIImage(cgImage: $0) }
              self.lastText = nil
              self.render(force: true)
            }
          }
          self.coverTask?.resume()
        }
      }
  }

  /// 设置页复用小窗的像素绘制，不启动系统画中画。
  @objc public func preview(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(PreviewRequest.self)
    DispatchQueue.main.async {
      self.applyContent(request.content)
      let now = ProcessInfo.processInfo.systemUptime
      if self.controller == nil {
        if self.playing {
          self.discAngle = (self.discAngle + (now - self.discAnchorTime) * .pi / 10)
            .truncatingRemainder(dividingBy: 2 * .pi)
        }
        self.discAnchorTime = now
        self.playing = request.playing
      }
      let angle = self.discAngle + (self.playing ? (now - self.discAnchorTime) * .pi / 10 : 0)
      let time = request.position + request.content.offset
      let row = LyricTimeline.primary(request.content.lines, at: time)
      let active = row.flatMap { time < $0.end + 3000 ? $0 : nil }
      let title = request.content.title.isEmpty ? "SPlayer Next" : request.content.title
      guard let buffer = self.drawFrame(active?.rows ?? [title, request.content.artist],
        primary: active?.primary ?? 0, angle: CGFloat(angle),
        words: active?.words ?? [], time: time, line: active, preview: true) else {
        invoke.reject("预览绘制失败")
        return
      }
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 160,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      guard let image = context?.makeImage(), let data = UIImage(cgImage: image).pngData() else {
        invoke.reject("预览图片生成失败")
        return
      }
      invoke.resolve(["image": "data:image/png;base64," + data.base64EncodedString()])
    }
  }

  @objc public func discard(_ invoke: Invoke) {
    DispatchQueue.main.async {
      if self.controller == nil && self.pendingStart == nil {
        self.coverTask?.cancel()
        self.coverTask = nil
        self.coverURL = ""
        self.coverImage = nil
        self.cachedFrame = nil
      }
      invoke.resolve()
    }
  }

  @objc public func sync(_ invoke: Invoke) throws {
    let next = try invoke.parseArgs(PlaybackAnchor.self)
    DispatchQueue.main.async {
      let delay = max(0, Date().timeIntervalSince1970 * 1000 - next.timestamp)
      let playbackChanged = self.playing != next.playing || self.duration != next.duration
      let now = ProcessInfo.processInfo.systemUptime
      if self.playing {
        self.discAngle = (self.discAngle + (now - self.discAnchorTime) * .pi / 10)
          .truncatingRemainder(dividingBy: 2 * .pi)
      }
      self.discAnchorTime = now
      self.position = next.position + (next.playing ? delay * next.speed : 0)
      self.duration = next.duration
      self.playing = next.playing
      self.speed = next.speed
      self.anchorTime = ProcessInfo.processInfo.systemUptime
      if playbackChanged { self.controller?.invalidatePlaybackState() }
      self.render()
      self.updateTimer()
      invoke.resolve()
    }
  }

  @objc public func start(_ invoke: Invoke) {
    DispatchQueue.main.async {
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        invoke.reject("此设备不支持歌词画中画")
        return
      }
      guard self.pendingStart == nil, self.controller == nil else {
        invoke.reject("歌词小窗已开启或正在启动")
        return
      }
      guard let parent = self.manager.viewController?.view else {
        invoke.reject("应用窗口尚未准备好")
        return
      }
      self.pendingStart = invoke
      let view = LyricVideoView(frame: CGRect(
        x: max(0, parent.bounds.width - 252),
        y: max(0, parent.bounds.height - parent.safeAreaInsets.bottom - 225),
        width: 240, height: 60))
      view.isUserInteractionEnabled = false
      view.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
      self.displayLayer = view.layer as! AVSampleBufferDisplayLayer
      // 主图层随视图布局；设置其 frame 会把整个视频源移到左上角。
      self.displayLayer.videoGravity = .resizeAspect
      // 视频源始终置于网页后方，避免启动动画或鼠标悬浮时露出内联占位控件。
      parent.insertSubview(view, at: 0)
      self.sourceView = view
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: self.displayLayer, playbackDelegate: self)
      let pip = AVPictureInPictureController(contentSource: source)
      pip.delegate = self
      pip.requiresLinearPlayback = true
      // 隐藏播放控件但保留关闭和返回；未公开接口需先确认 setter 可用。
      if pip.responds(to: NSSelectorFromString("setControlsStyle:")) {
        pip.setValue(1, forKey: "controlsStyle")
        self.log("controls-style=playback-hidden")
      } else {
        self.log("controls-style=system (hidden style unavailable)")
      }
      pip.canStartPictureInPictureAutomaticallyFromInline = false
      self.controller = pip
      self.suspension = pip.observe(\.isPictureInPictureSuspended, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async {
          self?.render(force: true)
          self?.updateTimer()
        }
      }
      self.lastText = nil
      self.frameCount = 0
      self.lastFrameTime = -.infinity
      self.render()
      self.updateTimer()
      self.readiness = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
        [weak self] pip, _ in
        DispatchQueue.main.async {
          guard let self = self, self.pendingStart != nil,
            self.controller === pip, pip.isPictureInPicturePossible else { return }
          self.readiness = nil
          pip.startPictureInPicture()
        }
      }
      let timeout = DispatchWorkItem { [weak self] in
        guard let self = self, self.pendingStart != nil else { return }
        self.fail("系统未能开启歌词画中画，请先播放歌曲后重试")
      }
      self.startTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }
  }

  @objc public func stop(_ invoke: Invoke) {
    DispatchQueue.main.async {
      if self.controller?.isPictureInPictureActive == true {
        self.controller?.stopPictureInPicture()
      } else {
        self.pendingStart?.reject("已取消开启歌词小窗")
        self.pendingStart = nil
        self.cleanup()
      }
      invoke.resolve()
    }
  }

  /// 封面旋转使用二十帧；暂停、隐藏或无封面时保留低频调度。
  private func updateTimer() {
    timer?.invalidate()
    timer = nil
    guard (controller?.isPictureInPictureActive == true && controller?.isPictureInPictureSuspended == false) || pendingStart != nil else {
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    var delay = max(0.2, 1 - (now - lastFrameTime))
    if playing && coverImage != nil {
      delay = max(0.005, 0.05 - (now - lastFrameTime))
    }
    if playing && speed > 0, let content = content {
      let time = currentPosition() + content.offset
      if let next = content.lines.first(where: { $0.start > time }) {
        delay = min(delay, max(0.02, (next.start - time) / (1000 * speed)))
      }
      if let current = LyricTimeline.primary(content.lines, at: time), current.end + 3000 > time {
        delay = min(delay, max(0.02, (current.end + 3000 - time) / (1000 * speed)))
        if time < current.end || lyricRenderer.isAnimating {
          delay = min(delay, max(0.005, 0.05 - (now - lastFrameTime)))
        }
      }
    }
    if lyricRenderer.isAnimating { delay = min(delay, 0.05) }
    let nextTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      self?.render()
      self?.updateTimer()
    }
    nextTimer.tolerance = 0.002
    timer = nextTimer
    RunLoop.main.add(nextTimer, forMode: .common)
  }

  private func currentPosition() -> Double {
    let elapsed = (ProcessInfo.processInfo.systemUptime - anchorTime) * 1000
    let value = position + (playing ? elapsed * speed : 0)
    return duration > 0 ? min(duration, value) : value
  }

  /// 内容未变化时复用当前像素缓冲，以低频新时间戳重送，供画中画切换和暂停后恢复显示。
  private func render(force: Bool = false) {
    guard sourceView != nil else { return }
    if pendingStart == nil && controller?.isPictureInPictureSuspended == true { return }
    let now = ProcessInfo.processInfo.systemUptime
    let needsFlush = displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding
    if needsFlush {
      reportRenderError("display-layer: \(displayLayer.error?.localizedDescription ?? "requires flush")")
      displayLayer.flush()
    }
    guard displayLayer.isReadyForMoreMediaData else { return }
    let time = currentPosition() + (content?.offset ?? 0)
    let line = LyricTimeline.primary(content?.lines ?? [], at: time)
    let active = line.flatMap { time < $0.end + 3000 ? $0 : nil }
    let title = content?.title.isEmpty == false ? content!.title : "SPlayer Next"
    let info = [title, content?.artist ?? ""].filter { !$0.isEmpty }.joined(separator: " - ")
    let text = active?.rows ?? [title, info]
    let primary = active?.primary ?? 0
    let words = active?.words ?? []
    let animateDisc = playing && coverImage != nil && now - lastFrameTime >= 0.045
    let animateLyrics = (active != nil && time != lastLyricTime || lyricRenderer.isAnimating) &&
      (!playing || force || now - lastFrameTime >= 0.045)
    if text != lastText || primary != lastPrimary || cachedFrame == nil || animateDisc || animateLyrics {
      let angle = discAngle + (playing ? (now - discAnchorTime) * .pi / 10 : 0)
      guard let buffer = drawFrame(text, primary: primary, angle: CGFloat(angle), words: words, time: time, line: active) else { return }
      cachedFrame = buffer
      lastText = text
      lastPrimary = primary
      lastLyricTime = time
    } else if !force && !needsFlush && now - lastFrameTime < 1 {
      return
    }
    guard let buffer = cachedFrame else { return }
    var format: CMVideoFormatDescription?
    let formatResult = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescriptionOut: &format)
    guard formatResult == noErr, let format = format else {
      reportRenderError("video-format: \(formatResult)")
      return
    }
    // displayLayer 未设置 controlTimebase，PTS 必须使用 host clock，不能始终为零。
    var timing = CMSampleTimingInfo(duration: CMTime(seconds: 2, preferredTimescale: 600),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let sampleResult = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    guard sampleResult == noErr, let sample = sample else {
      reportRenderError("sample-buffer: \(sampleResult)")
      return
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    displayLayer.enqueue(sample)
    lastFrameTime = now
    frameCount += 1
    if frameCount == 1 || frameCount % 30 == 0 {
      log("frames=\(frameCount) status=\(displayLayer.status.rawValue) ready=\(displayReadiness) surface=\(CVPixelBufferGetIOSurface(buffer) != nil) bytes=\(CVPixelBufferGetDataSize(buffer))")
    }
  }

  /// 使用可共享的 IOSurface，并在送往系统显示层之前结束 CPU 写入锁。
  private func drawFrame(_ text: [String], primary: Int, angle: CGFloat, words: [TimedWord], time: Double,
    line: LyricRow?, preview: Bool = false) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
      kCVPixelBufferMetalCompatibilityKey: true
    ]
    let result = CVPixelBufferCreate(kCFAllocatorDefault, 640, 160, kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &pixelBuffer)
    guard result == kCVReturnSuccess, let buffer = pixelBuffer else {
      reportRenderError("pixel-buffer: \(result)")
      return nil
    }
    let lockResult = CVPixelBufferLockBaseAddress(buffer, [])
    guard lockResult == kCVReturnSuccess else {
      reportRenderError("pixel-buffer-lock: \(lockResult)")
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640,
      height: 160, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else {
      reportRenderError("bitmap-context: creation failed")
      return nil
    }
    context.setFillColor(UIColor(white: 0.17, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
    context.translateBy(x: 0, y: 160)
    context.scaleBy(x: 1, y: -1)
    UIGraphicsPushContext(context)
    let disc = CGRect(x: 20, y: 24, width: 112, height: 112)
    context.setFillColor(UIColor(white: 0.04, alpha: 1).cgColor)
    context.fillEllipse(in: disc)
    context.saveGState()
    // 固定裁切边缘，只旋转内部图像，避免圆周栅格化随角度抖动。
    let coverRect = disc.insetBy(dx: 16, dy: 16)
    context.addEllipse(in: coverRect)
    context.clip()
    context.interpolationQuality = .high
    context.translateBy(x: disc.midX, y: disc.midY)
    context.rotate(by: angle)
    context.translateBy(x: -disc.midX, y: -disc.midY)
    if let image = coverImage {
      let scale = max(coverRect.width / image.size.width, coverRect.height / image.size.height)
      let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      image.draw(in: CGRect(x: coverRect.midX - size.width / 2, y: coverRect.midY - size.height / 2,
        width: size.width, height: size.height))
    } else {
      context.setFillColor(UIColor.darkGray.cgColor)
      context.fill(coverRect)
    }
    context.restoreGState()
    if let style = content?.style {
      (preview ? previewRenderer : lyricRenderer).draw(context: context, text: text,
        line: line, style: style, time: time, animated: !preview)
    }
    UIGraphicsPopContext()
    context.flush()
    return buffer
  }

  private func reportRenderError(_ message: String) {
    guard lastRenderError != message else { return }
    lastRenderError = message
    log("render-error: \(message)")
  }

  /// 应用已将 stderr 重定向到共享日志，直接写入以免只落到系统统一日志。
  private func log(_ message: String) {
    fputs("[lyric-pip] \(message)\n", stderr)
  }

  private func cleanup() {
    startTimeout?.cancel()
    startTimeout = nil
    readiness = nil
    suspension = nil
    timer?.invalidate()
    timer = nil
    controller?.delegate = nil
    controller = nil
    displayLayer.flushAndRemoveImage()
    displayLayer.removeFromSuperlayer()
    sourceView?.removeFromSuperview()
    sourceView = nil
    content = nil
    lyricRenderer.reset()
    previewRenderer.reset()
    lastText = nil
    lastPrimary = -1
    lastLyricTime = -.infinity
    cachedFrame = nil
    coverTask?.cancel()
    coverTask = nil
    coverURL = ""
    coverImage = nil
    discAngle = 0
    discAnchorTime = ProcessInfo.processInfo.systemUptime
    lastFrameTime = -.infinity
    lastRenderError = nil
    log("stopped frames=\(frameCount)")
    trigger("visibility", data: ["active": false])
  }

  private func fail(_ message: String) {
    log(message)
    pendingStart?.reject(message)
    pendingStart = nil
    cleanup()
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    // 保留视频源供系统读取，但把“正在画中画播放”的占位层放到网页后面。
    if let view = sourceView { view.superview?.sendSubviewToBack(view) }
    startTimeout?.cancel()
    startTimeout = nil
    pendingStart?.resolve()
    pendingStart = nil
    trigger("visibility", data: ["active": true])
    log("started ready=\(displayReadiness)")
    render(force: true)
    updateTimer()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    cleanup()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    fail(error.localizedDescription)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    completionHandler(true)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    trigger("playback", data: ["playing": playing])
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    !playing
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    log("render-size=\(newRenderSize.width)x\(newRenderSize.height)")
    render(force: true)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    completionHandler()
  }
}

@_cdecl("init_plugin_lyric_pip")
func initPlugin() -> Plugin {
  if #available(iOS 15.0, *) { return LyricPipPlugin() }
  return Plugin()
}
