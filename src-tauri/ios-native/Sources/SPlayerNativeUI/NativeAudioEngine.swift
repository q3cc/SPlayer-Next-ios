import AVFoundation
import AudioStreaming

/// 复用 Next iOS 已有的 AudioStreaming 解码器及原生音效链
@MainActor
final class NativeAudioEngine: NSObject, AudioPlayerDelegate {
  private var player: AudioPlayer?
  private var equalizer = AVAudioUnitEQ(numberOfBands: 10)
  private var pitchNode = AVAudioUnitTimePitch()
  private var normalizationNode = AVAudioUnitEQ(numberOfBands: 0)
  private let normalizer = AudioAnalysis()
  private var normalizationTimer: Timer?
  private var fadeTimer: Timer?
  private var fadeLevel: Float = 1
  var fadeDuration = 0.0
  var normalization = false { didSet { updateTap() } }
  private var tapInstalled = false
  private var analysis: NativeAudioSpectrum?
  var onState: (() -> Void)?
  var onEnded: (() -> Void)?
  var onError: ((String) -> Void)?
  var loaded: Bool { player != nil }
  var playing: Bool { player?.state == .playing }
  var position: Double { (player?.progress ?? 0) * 1000 }
  var duration: Double { (player?.duration ?? 0) * 1000 }
  var volume: Float = 1 { didSet { player?.volume = volume * fadeLevel } }
  var rate: Float = 1 { didSet { apply() } }
  var pitch: Float = 0 { didSet { apply() } }
  var pitchSync = true { didSet { apply() } }
  var eqEnabled = false { didSet { apply() } }
  var bands = [Float](repeating: 0, count: 10) { didSet { apply() } }
  var preamp: Float = 0 { didSet { apply() } }
  private var pendingSeek: Double?

  /// 新曲目使用独立引擎实例，旧曲目的迟到回调不能覆盖当前播放
  func load(_ url: URL) {
    stop()
    equalizer = AVAudioUnitEQ(numberOfBands: 10)
    pitchNode = AVAudioUnitTimePitch()
    let next = AudioPlayer()
    normalizationNode = AVAudioUnitEQ(numberOfBands: 0)
    next.attach(nodes: [equalizer, pitchNode, normalizationNode])
    next.delegate = self
    player = next
    apply()
    fadeLevel = fadeDuration > 0 ? 0 : 1
    next.volume = volume * fadeLevel
    next.play(url: url)
    updateTap()
  }
  /// 系统播放命令与界面使用同一个真实引擎
  func play() { player?.resume() }
  /// 暂停不卸载音源，以便恢复和拖动
  func pause(immediate: Bool = false) {
    if immediate {
      fadeTimer?.invalidate()
      fadeTimer = nil
      player?.pause()
      return
    }
    fade(to: 0) { [weak self] in self?.player?.pause() }
  }
  /// 停止时先移除音频 tap，再释放引擎和旧回调
  func stop() {
    fadeTimer?.invalidate()
    fadeTimer = nil
    normalizationTimer?.invalidate()
    normalizationTimer = nil
    if tapInstalled {
      pitchNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    analysis = nil
    player?.delegate = nil
    player?.stop()
    player = nil
    pendingSeek = nil
  }
  /// 缓冲期间保存目标位置，开始播放时再交给引擎定位
  func seek(_ milliseconds: Double) {
    if let player, player.duration > 0 {
      player.seek(to: milliseconds / 1000)
    } else {
      pendingSeek = milliseconds
    }
  }
  /// 与旧版 iOS 相同的十段 EQ、前级增益和保调/变调节点
  private func apply() {
    player?.rate = rate
    pitchNode.pitch = pitchSync ? pitch * 100 : 1200 * log2(rate)
    pitchNode.bypass = pitchNode.pitch == 0
    for (i, frequency) in [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].enumerated() {
      let band = equalizer.bands[i]
      band.filterType = .parametric
      band.frequency = Float(frequency)
      band.bandwidth = 1
      band.gain = bands[i]
      band.bypass = !eqEnabled
    }
    equalizer.globalGain = eqEnabled ? preamp : 0
  }
  /// 只在有可见消费者时采集真实音频 PCM
  func setAnalysis(_ analysis: NativeAudioSpectrum?) {
    self.analysis = analysis
    updateTap()
  }
  /// 响度采样放在补偿节点前，频谱与响度共享同一个 tap
  private func updateTap() {
    normalizationTimer?.invalidate()
    normalizationTimer = nil
    if tapInstalled {
      pitchNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    normalizer.configure(spectrum: false, normalize: normalization)
    if !normalization { normalizationNode.globalGain = 0 }
    guard player != nil, analysis != nil || normalization else { return }
    let analysis = self.analysis
    let normalizer = self.normalizer
    let normalize = normalization
    pitchNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
      analysis?.push(
        buffer.mutableAudioBufferList, frames: Int(buffer.frameLength),
        format: buffer.format.streamDescription.pointee)
      if normalize { normalizer.process(buffer) }
    }
    tapInstalled = true
    if normalization {
      normalizationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
        [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.playing, let result = self.normalizer.consume() else { return }
          self.normalizationNode.globalGain = 20 * log10(max(result.gain, 0.001))
        }
      }
    }
  }
  /// 复用 Next iOS 的线性淡入淡出时间与 10ms 更新间隔
  private func fade(to target: Float, completion: (() -> Void)? = nil) {
    fadeTimer?.invalidate()
    fadeTimer = nil
    guard let expectedPlayer = player else { return }
    guard fadeDuration > 0 else {
      fadeLevel = target
      player?.volume = volume * target
      completion?()
      return
    }
    let start = Date()
    let initial = fadeLevel
    let duration = fadeDuration / 1000
    let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self, weak expectedPlayer] timer in
      Task { @MainActor [weak self, weak expectedPlayer] in
        guard let self, timer.isValid, self.player === expectedPlayer else {
          timer.invalidate()
          return
        }
        let progress = min(1, Float(Date().timeIntervalSince(start) / duration))
        self.fadeLevel = initial + (target - initial) * progress
        self.player?.volume = self.volume * self.fadeLevel
        if progress >= 1 {
          timer.invalidate()
          self.fadeTimer = nil
          completion?()
        }
      }
    }
    fadeTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  nonisolated func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {}
  /// 引擎状态回到主线程后再通知 SwiftUI
  nonisolated func audioPlayerStateChanged(
    player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState
  ) {
    Task { @MainActor [weak self] in
      guard let self, self.player === player else { return }
      if player.state == .playing, let target = self.pendingSeek {
        self.pendingSeek = nil
        player.seek(to: target / 1000)
      }
      if newState == .playing { self.fade(to: 1) }
      self.onState?()
    }
  }
  /// 自然播放结束才推进队列，用户停止和切歌不触发下一首
  nonisolated func audioPlayerDidFinishPlaying(
    player: AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double,
    duration: Double
  ) {
    guard stopReason == .eof else { return }
    Task { @MainActor [weak self] in
      guard let self, self.player === player else { return }
      self.onEnded?()
    }
  }
  /// 错误保留真实解码原因，不伪造继续播放
  nonisolated func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
    Task { @MainActor [weak self] in
      guard let self, self.player === player else { return }
      self.onError?(error.localizedDescription)
    }
  }
  nonisolated func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId) {}
  nonisolated func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}
  nonisolated func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}
}
