import Combine
import Foundation
import os

#if os(iOS)
  import AVFoundation
  import AVKit
  import ImageIO
  import UIKit
#endif

/// 歌词画中画：AVSampleBufferDisplayLayer 逐帧送入系统小窗，移植自 Tauri 版 lyric-pip 插件
final class NativeLyricPiP: NSObject, ObservableObject {
  private let log = Logger(subsystem: "top.imsyy.splayer-next.native", category: "lyric-pip")
  @Published private(set) var active = false
  @Published private(set) var starting = false
  private weak var player: NativePlayerStore?
  private var content: NativePiPContent?
  private var subscriptions: Set<AnyCancellable> = []
  /// 引擎进度锚点：读取到的进度按倍速外推，避免逐帧量化抖动
  private var anchorPosition = 0.0
  private var anchorTime = ProcessInfo.processInfo.systemUptime
  private var anchorPlaying = false
  private var discAngle = 0.0
  private var discAnchorTime = ProcessInfo.processInfo.systemUptime
  #if os(iOS)
    private var displayLayer = AVSampleBufferDisplayLayer()
    private var sourceView: UIView?
    private var controller: AVPictureInPictureController?
    private var readiness: NSKeyValueObservation?
    private var suspension: NSKeyValueObservation?
    private var startTimeout: DispatchWorkItem?
    private var timer: Timer?
    private var lastText: [String]?
    private var lastPrimary = -1
    private var lastLyricTime = -Double.infinity
    private var cachedFrame: CVPixelBuffer?
    private var lastFrameTime = -Double.infinity
    private var coverKey: String?
    private var coverImage: UIImage?
    private var coverTask: Task<Void, Never>?
    private let lyricRenderer = NativePiPRenderer()
    private let previewRenderer = NativePiPRenderer()
    private var frameInterval: Double { NativePiPTimeline.frameInterval(content?.style.frameRate) }
  #endif

  init(player: NativePlayerStore) {
    self.player = player
    super.init()
  }

  static var supported: Bool {
    #if os(iOS)
      return AVPictureInPictureController.isPictureInPictureSupported()
    #else
      return false
    #endif
  }

  @MainActor func toggle() {
    log.notice("toggle active=\(self.active) starting=\(self.starting)")
    if active || starting { stop() } else { start() }
  }

  /// 当前歌曲、歌词、偏移或小窗设置变化时重建内容
  @MainActor private func rebuild() {
    guard let player else { return }
    let next = NativePiPContent.make(
      title: player.current?.title ?? "", artist: player.current?.artist ?? "",
      cover: player.current?.cover, offset: player.lyricOffsetMs, lyrics: player.lyrics,
      options: .current())
    guard next != content else { return }
    content = next
    #if os(iOS)
      lastText = nil
      loadCover(next.cover)
      render(force: true)
      updateTimer()
    #endif
  }

  /// 播放速度；所有绘制都在主线程执行
  private var speed: Double {
    guard let player else { return 1 }
    return MainActor.assumeIsolated { player.speed }
  }

  /// 引擎进度在后台仍可读取；与外推值相差较大或播放状态变化时重设锚点
  private func currentPosition() -> Double {
    let now = ProcessInfo.processInfo.systemUptime
    let speed = self.speed
    let predicted = anchorPosition + (anchorPlaying ? (now - anchorTime) * 1000 * speed : 0)
    guard let player = player else { return predicted }
    let (live, playing) = MainActor.assumeIsolated { (player.livePositionMs, player.isPlaying) }
    if playing != anchorPlaying || abs(live - predicted) > 150 {
      if anchorPlaying {
        discAngle = (discAngle + (now - discAnchorTime) * .pi / 10)
          .truncatingRemainder(dividingBy: 2 * .pi)
      }
      discAnchorTime = now
      anchorPosition = live
      anchorTime = now
      anchorPlaying = playing
      return live
    }
    return predicted
  }

  @MainActor func start() {
    #if os(iOS)
      guard let player else { return }
      guard Self.supported else {
        log.error("start blocked: 此设备不支持歌词画中画")
        player.error = "此设备不支持歌词画中画"
        return
      }
      guard controller == nil, !starting else {
        log.notice("start ignored: controller exists or starting")
        return
      }
      guard player.current != nil else {
        log.error("start blocked: 请先选择并播放一首歌曲，再开启歌词小窗")
        player.error = "请先选择并播放一首歌曲，再开启歌词小窗"
        return
      }
      guard
        let parent = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController?.view
      else {
        log.error("start blocked: 应用窗口尚未准备好")
        player.error = "应用窗口尚未准备好"
        return
      }
      log.notice("start requested")
      starting = true
      subscribe()
      rebuild()
      let view = NativePiPVideoView(
        frame: CGRect(
          x: max(0, parent.bounds.width - 252),
          y: max(0, parent.bounds.height - parent.safeAreaInsets.bottom - 225), width: 240,
          height: 60))
      view.isUserInteractionEnabled = false
      view.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
      displayLayer = view.layer as! AVSampleBufferDisplayLayer
      // 主图层随视图布局；视频源放在界面后方，不露出占位控件
      displayLayer.videoGravity = .resizeAspect
      parent.insertSubview(view, at: 0)
      sourceView = view
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
      let pip = AVPictureInPictureController(contentSource: source)
      pip.delegate = self
      pip.requiresLinearPlayback = true
      // 隐藏播放控件但保留关闭和返回；未公开接口先确认 setter 可用
      if pip.responds(to: NSSelectorFromString("setControlsStyle:")) {
        pip.setValue(1, forKey: "controlsStyle")
      }
      pip.canStartPictureInPictureAutomaticallyFromInline = false
      controller = pip
      suspension = pip.observe(\.isPictureInPictureSuspended, options: [.new]) {
        [weak self] _, _ in
        DispatchQueue.main.async {
          self?.render(force: true)
          self?.updateTimer()
        }
      }
      lastText = nil
      lastFrameTime = -.infinity
      render()
      updateTimer()
      readiness = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
        [weak self] pip, _ in
        DispatchQueue.main.async {
          guard let self, self.starting, self.controller === pip, pip.isPictureInPicturePossible
          else { return }
          self.readiness = nil
          pip.startPictureInPicture()
        }
      }
      let timeout = DispatchWorkItem { [weak self] in
        guard let self, self.starting else { return }
        self.log.error("start timed out")
        MainActor.assumeIsolated {
          self.player?.error = "系统未能开启歌词画中画，请先播放歌曲后重试"
        }
        self.cleanup()
      }
      startTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    #endif
  }

  @MainActor func stop() {
    #if os(iOS)
      if controller?.isPictureInPictureActive == true {
        controller?.stopPictureInPicture()
      } else {
        cleanup()
      }
    #endif
  }

  @MainActor private func subscribe() {
    guard subscriptions.isEmpty, let player else { return }
    let refresh: () -> Void = { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuild() } }
    }
    player.$lyrics.sink { _ in refresh() }.store(in: &subscriptions)
    player.$current.sink { _ in refresh() }.store(in: &subscriptions)
    player.$lyricOffsetMs.sink { _ in refresh() }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .sink { _ in refresh() }.store(in: &subscriptions)
    player.$isPlaying.sink { [weak self] _ in
      DispatchQueue.main.async {
        #if os(iOS)
          self?.controller?.invalidatePlaybackState()
          self?.render(force: true)
          self?.updateTimer()
        #endif
      }
    }.store(in: &subscriptions)
  }

  #if os(iOS)
    /// 唱片只需要 112px 缩略图，不在小窗保留大封面
    private func loadCover(_ value: String?) {
      guard value != coverKey else { return }
      coverKey = value
      coverImage = nil
      coverTask?.cancel()
      guard let value else { return }
      coverTask = Task { [weak self] in
        let image = await NativeArtworkCache.shared.image(value, pixels: 112)
        await MainActor.run {
          guard let self, self.coverKey == value else { return }
          self.coverImage = image.map { UIImage(cgImage: $0) }
          self.lastText = nil
          self.render(force: true)
        }
      }
    }

    /// 设置页预览复用小窗绘制，不启动系统画中画
    @MainActor func preview() -> UIImage? {
      guard let player else { return nil }
      let options = NativePiPOptions.current()
      let content = NativePiPContent.make(
        title: player.current?.title ?? "", artist: player.current?.artist ?? "",
        cover: player.current?.cover, offset: player.lyricOffsetMs, lyrics: player.lyrics,
        options: options)
      if controller == nil { loadCover(content.cover) }
      let time = currentPosition() + content.offset
      let now = ProcessInfo.processInfo.systemUptime
      let angle = discAngle + (anchorPlaying ? (now - discAnchorTime) * .pi / 10 : 0)
      let row = NativePiPTimeline.primary(content.lines, at: time)
      let active = row.flatMap { time < $0.end + 3000 ? $0 : nil }
      let title = content.title.isEmpty ? "SPlayer Next" : content.title
      guard
        let buffer = drawFrame(
          active?.rows ?? [title, content.artist], line: active, style: content.style,
          angle: CGFloat(angle), time: time, renderer: previewRenderer, animated: false)
      else { return nil }
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      guard
        let context = CGContext(
          data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 160, bitsPerComponent: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        let image = context.makeImage()
      else { return nil }
      return UIImage(cgImage: image)
    }

    /// 按帧率调度；暂停或小窗挂起时降为低频刷新
    private func updateTimer() {
      timer?.invalidate()
      timer = nil
      guard
        (controller?.isPictureInPictureActive == true
          && controller?.isPictureInPictureSuspended == false) || starting
      else { return }
      let now = ProcessInfo.processInfo.systemUptime
      let playing = anchorPlaying
      let speed = self.speed
      var delay = max(0.2, 1 - (now - lastFrameTime))
      if playing && coverImage != nil {
        delay = max(0.001, frameInterval - (now - lastFrameTime))
      }
      if playing && speed > 0, let content {
        let time = currentPosition() + content.offset
        if let next = content.lines.first(where: { $0.start > time }) {
          delay = min(delay, max(0.02, (next.start - time) / (1000 * speed)))
        }
        if let current = NativePiPTimeline.primary(content.lines, at: time),
          current.end + 3000 > time
        {
          delay = min(delay, max(0.02, (current.end + 3000 - time) / (1000 * speed)))
          if time < current.end || lyricRenderer.isAnimating {
            delay = min(delay, max(0.001, frameInterval - (now - lastFrameTime)))
          }
        }
      }
      if lyricRenderer.isAnimating {
        delay = min(delay, max(0.001, frameInterval - (now - lastFrameTime)))
      }
      let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
        self?.render()
        self?.updateTimer()
      }
      next.tolerance = 0.002
      timer = next
      RunLoop.main.add(next, forMode: .common)
    }

    /// 内容未变化时复用像素缓冲，以低频新时间戳重送，供暂停后恢复显示
    private func render(force: Bool = false) {
      guard sourceView != nil, let content else { return }
      if !starting && controller?.isPictureInPictureSuspended == true { return }
      let now = ProcessInfo.processInfo.systemUptime
      let needsFlush = displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding
      if needsFlush { displayLayer.flush() }
      guard displayLayer.isReadyForMoreMediaData else { return }
      let time = currentPosition() + content.offset
      let line = NativePiPTimeline.primary(content.lines, at: time)
      let active = line.flatMap { time < $0.end + 3000 ? $0 : nil }
      let title = content.title.isEmpty ? "SPlayer Next" : content.title
      let info = [title, content.artist].filter { !$0.isEmpty }.joined(separator: " - ")
      let text = active?.rows ?? [title, info]
      let primary = active?.primary ?? 0
      let animateDisc =
        anchorPlaying && coverImage != nil && now - lastFrameTime >= frameInterval - 0.001
      let animateLyrics =
        (active != nil && time != lastLyricTime || lyricRenderer.isAnimating)
        && (force || now - lastFrameTime >= frameInterval - 0.001)
      if text != lastText || primary != lastPrimary || cachedFrame == nil || animateDisc
        || animateLyrics
      {
        let angle = discAngle + (anchorPlaying ? (now - discAnchorTime) * .pi / 10 : 0)
        guard
          let buffer = drawFrame(
            text, line: active, style: content.style, angle: CGFloat(angle), time: time,
            renderer: lyricRenderer, animated: true)
        else { return }
        cachedFrame = buffer
        lastText = text
        lastPrimary = primary
        lastLyricTime = time
      } else if !force && !needsFlush && now - lastFrameTime < 1 {
        return
      }
      guard let buffer = cachedFrame else { return }
      var format: CMVideoFormatDescription?
      guard
        CMVideoFormatDescriptionCreateForImageBuffer(
          allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
          == noErr, let format
      else { return }
      // 显示层没有 controlTimebase，PTS 必须使用 host clock
      var timing = CMSampleTimingInfo(
        duration: CMTime(seconds: 2, preferredTimescale: 600),
        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
        decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      guard
        CMSampleBufferCreateReadyWithImageBuffer(
          allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
          sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample
      else { return }
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
      {
        let dictionary = unsafeBitCast(
          CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
          dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
          Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
      }
      displayLayer.enqueue(sample)
      lastFrameTime = now
    }

    /// 640×160 画布：左侧旋转唱片，右侧最多三行歌词；IOSurface 供系统显示层共享
    private func drawFrame(
      _ text: [String], line: NativePiPRow?, style: NativePiPStyle, angle: CGFloat, time: Double,
      renderer: NativePiPRenderer, animated: Bool
    ) -> CVPixelBuffer? {
      var pixelBuffer: CVPixelBuffer?
      let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      guard
        CVPixelBufferCreate(
          kCFAllocatorDefault, 640, 160, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
          &pixelBuffer) == kCVReturnSuccess, let buffer = pixelBuffer,
        CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess
      else { return nil }
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      guard
        let context = CGContext(
          data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 160, bitsPerComponent: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return nil }
      context.setFillColor(UIColor(white: 0.17, alpha: 1).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
      context.translateBy(x: 0, y: 160)
      context.scaleBy(x: 1, y: -1)
      UIGraphicsPushContext(context)
      let disc = CGRect(x: 20, y: 24, width: 112, height: 112)
      context.setFillColor(UIColor(white: 0.04, alpha: 1).cgColor)
      context.fillEllipse(in: disc)
      context.saveGState()
      // 固定裁切边缘，只旋转内部图像，避免圆周随角度抖动
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
        image.draw(
          in: CGRect(
            x: coverRect.midX - size.width / 2, y: coverRect.midY - size.height / 2,
            width: size.width, height: size.height))
      } else {
        context.setFillColor(UIColor.darkGray.cgColor)
        context.fill(coverRect)
      }
      context.restoreGState()
      renderer.draw(
        context: context, text: text, line: line, style: style, time: time, animated: animated)
      UIGraphicsPopContext()
      context.flush()
      return buffer
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
      sourceView?.removeFromSuperview()
      sourceView = nil
      lyricRenderer.reset()
      lastText = nil
      lastPrimary = -1
      lastLyricTime = -.infinity
      cachedFrame = nil
      lastFrameTime = -.infinity
      subscriptions.removeAll()
      content = nil
      starting = false
      active = false
    }
  #endif
}

#if os(iOS)
  /// 显示层作为视图主图层，随窗口尺寸变化同步布局
  private final class NativePiPVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  }

  extension NativeLyricPiP: AVPictureInPictureControllerDelegate,
    AVPictureInPictureSampleBufferPlaybackDelegate
  {
    func pictureInPictureControllerDidStartPictureInPicture(
      _ pictureInPictureController: AVPictureInPictureController
    ) {
      // SwiftUI 背景绘制在宿主视图自身图层，无法遮住视频源；开启后隐藏“正在画中画播放”占位
      if let view = sourceView {
        view.superview?.sendSubviewToBack(view)
        view.alpha = 0
      }
      startTimeout?.cancel()
      startTimeout = nil
      starting = false
      active = true
      log.notice("started")
      render(force: true)
      updateTimer()
    }

    /// 返回应用时恢复视频源，系统收起动画需要可见的源视图
    func pictureInPictureControllerWillStopPictureInPicture(
      _ pictureInPictureController: AVPictureInPictureController
    ) {
      sourceView?.alpha = 1
    }

    func pictureInPictureControllerDidStopPictureInPicture(
      _ pictureInPictureController: AVPictureInPictureController
    ) {
      cleanup()
    }

    func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      failedToStartPictureInPictureWithError error: Error
    ) {
      log.error("failed: \(error.localizedDescription, privacy: .public)")
      MainActor.assumeIsolated { player?.error = error.localizedDescription }
      cleanup()
    }

    func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
        @escaping (Bool) -> Void
    ) {
      completionHandler(true)
    }

    func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
    ) {
      MainActor.assumeIsolated {
        if let player, player.isPlaying != playing { player.togglePlayback() }
      }
    }

    func pictureInPictureControllerTimeRangeForPlayback(
      _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
      CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
      _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
      !anchorPlaying
    }

    func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
      render(force: true)
    }

    func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
      completionHandler()
    }
  }

  /// 只缓存当前三行及退场三行的排版，逐帧不重复测量整句与词宽
  final class NativePiPRenderer {
    private struct Row {
      let text: NSAttributedString
      let highlighted: NSAttributedString
      let width: CGFloat
      let height: CGFloat
      let y: CGFloat
      let wordEdges: [(CGFloat, CGFloat)]
    }
    private var rows: [Row] = []
    private var previous: [Row] = []
    private var texts: [String] = []
    private var words: [NativePiPWord] = []
    private var style: NativePiPStyle?
    private var fonts: [String?] = []
    private var start = -Double.infinity
    private var activatedAt = 0.0
    private var transitionAt = -Double.infinity
    var isAnimating: Bool { ProcessInfo.processInfo.systemUptime - transitionAt < 0.4 }

    func reset() {
      rows = []
      previous = []
      texts = []
      words = []
      style = nil
      fonts = []
      start = -.infinity
      transitionAt = -.infinity
    }

    func draw(
      context: CGContext, text: [String], line: NativePiPRow?, style: NativePiPStyle,
      time: Double, animated: Bool
    ) {
      let now = ProcessInfo.processInfo.systemUptime
      let lineStart = line?.start ?? -1
      // 各行按文字语言使用歌词字体设置
      let families = text.prefix(3).map {
        NativeLyricFonts.family(for: NativeLyricLanguage.detect($0))
      }
      if texts != text || self.style != style || start != lineStart
        || words != (line?.words ?? []) || fonts != families
      {
        previous = rows
        let sameLine = start == lineStart && texts == text
        if !sameLine { activatedAt = max(line?.start ?? time, time) }
        transitionAt = animated && !rows.isEmpty && !sameLine ? now : -.infinity
        texts = text
        words = line?.words ?? []
        self.style = style
        fonts = families
        start = lineStart
        let count = min(3, text.count)
        let fontSize = min(
          CGFloat(style.fontSize),
          (140 - CGFloat(max(0, count - 1)) * 6) / (1.35 + CGFloat(max(0, count - 1)) * 1.08))
        let heights = text.prefix(3).indices.map { index in fontSize * (index == 0 ? 1.35 : 1.08) }
        var y = (160 - (heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 6)) / 2
        let played = UIColor(cgColor: style.playedColor.cgColor)
        let unplayedColor = UIColor(cgColor: style.unplayedColor.cgColor)
        rows = text.prefix(3).enumerated().map { index, value in
          let font = NativeLyricFonts.platformFont(
            family: families[index], size: fontSize * (index == 0 ? 1 : 0.8),
            weight: index == 0 ? .semibold : .regular)
          let unplayed = index == 0 && (line?.words.isEmpty ?? true) ? played : unplayedColor
          let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: unplayed]
          let string = NSAttributedString(string: value, attributes: attributes)
          let highlighted = NSAttributedString(
            string: value, attributes: [.font: font, .foregroundColor: played])
          var prefix = ""
          let edges: [(CGFloat, CGFloat)] =
            index == 0
            ? (line?.words ?? []).map { word in
              let before = (String(prefix.drop(while: { $0.isWhitespace })) as NSString).size(
                withAttributes: attributes
              ).width
              prefix += word.text
              let after = (String(prefix.drop(while: { $0.isWhitespace })) as NSString).size(
                withAttributes: attributes
              ).width
              return (before, after)
            } : []
          defer { y += heights[index] + 6 }
          return Row(
            text: string, highlighted: highlighted, width: string.size().width,
            height: heights[index], y: y, wordEdges: edges)
        }
      }
      let transition = min(1, max(0, (now - transitionAt) / 0.4))
      let eased = CGFloat(1 - pow(1 - transition, 3))
      context.saveGState()
      context.clip(to: CGRect(x: 152, y: 10, width: 464, height: 140))
      if transition < 1 {
        context.setAlpha(1 - eased)
        for row in previous { row.text.draw(at: CGPoint(x: 152, y: row.y - 16 * eased)) }
      } else {
        previous = []
      }
      context.setAlpha(eased)
      for (index, row) in rows.enumerated() {
        // 下一句只预告开头；当前句及译文按同一时间轴滚动到末尾
        let isNext = index > 0 && line?.nextPreview == true
        let end = line?.end ?? time
        let offset =
          line == nil || isNext
          ? 0
          : NativePiPTimeline.scroll(
            time: time, start: activatedAt, end: end, distance: Double(row.width - 464))
        let point = CGPoint(x: 152 + CGFloat(offset), y: row.y + 16 * (1 - eased))
        row.text.draw(at: point)
        if index == 0, let line {
          context.saveGState()
          context.beginPath()
          var hasHighlight = false
          for (wordIndex, word) in line.words.enumerated() where wordIndex < row.wordEdges.count {
            let progress = NativePiPTimeline.sweep(word, lineStart: line.start, time: time)
            if progress <= 0 { continue }
            let (left, right) = row.wordEdges[wordIndex]
            context.addRect(
              CGRect(
                x: point.x + left, y: point.y, width: (right - left) * CGFloat(progress),
                height: row.height))
            hasHighlight = true
          }
          if hasHighlight {
            context.clip()
            row.highlighted.draw(at: point)
          }
          context.restoreGState()
        }
      }
      context.restoreGState()
    }
  }
#endif
