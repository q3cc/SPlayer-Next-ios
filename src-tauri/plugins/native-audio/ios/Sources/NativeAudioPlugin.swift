import AVFoundation
import AudioStreaming
import MediaPlayer
import Tauri
import UIKit
import WebKit

private struct SourceRequest: Decodable {
  let source: String
  let autoPlay: Bool
  let trackId: String?
}
private struct ControlRequest: Decodable {
  let action: String
  let position: Double?
}
private struct MetadataRequest: Decodable {
  let title: String
  let artist: String
  let album: String
  let cover: String
  let enabled: Bool
  let dynamic: Bool?
  let offset: Double?
  let lines: [ControlLyric]?
}
private struct ControlLyric: Decodable {
  let start: Double
  let end: Double
  let text: String
}
private struct VisibilityRequest: Decodable { let visible: Bool }
private struct SiriRequest: Decodable { let request: String }
private struct SystemVolumeRequest: Decodable {
  let show: Bool?
  let x: Double?
  let y: Double?
  let value: Float?
  let viewportWidth: Double?
  let viewportHeight: Double?
}

private struct PlaybackCompletion {
  let callback: (Result<JSObject, Error>) -> Void
  func resolve(_ value: JSObject) { callback(.success(value)) }
  func reject(_ message: String) { callback(.failure(NSError(domain: "SPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))) }
}

final class NativeAudioPlugin: Plugin, AudioPlayerDelegate {
  static let shared = NativeAudioPlugin()
  private var player: AudioPlayer?
  private var audioEffects = AudioEffects()
  private var effects: EffectRequest = {
    if let data = UserDefaults.standard.data(forKey: "splayer.native.audio-effects"),
       let value = try? JSONDecoder().decode(EffectRequest.self, from: data) { return value }
    return EffectRequest(volume: 1, speed: 1, pitch: 0, pitchSync: true,
      enabled: false, bands: Array(repeating: 0, count: 10), preamp: 0)
  }()
  private var pendingLoad: PlaybackCompletion?
  private var loadTimeout: DispatchWorkItem?
  private var autoPlay = true
  private var sourceURL: URL?
  private(set) var currentTrackId: String?
  private var visible = false
  private var timer: Timer?
  private var remoteTargets: [(MPRemoteCommand, Any)] = []
  private var observers: [NSObjectProtocol] = []
  private var resumeAfterInterruption = false
  private var artworkTask: URLSessionDataTask?
  private var artworkURL = ""
  private var mediaEnabled = true
  private var metadataValue: MetadataRequest?
  private var lastLyricUpdate = Date.distantPast
  private var lastPlaybackCheckpoint = Date.distantPast
  private lazy var volumeView = MPVolumeView(frame: CGRect(x: 16, y: 10, width: 208, height: 32))
  private lazy var volumeLabel = UILabel(frame: CGRect(x: 16, y: 44, width: 208, height: 22))
  private lazy var volumeOverlay = UIControl()
  private lazy var volumePanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
  private var volumeObservation: NSKeyValueObservation?
  private var volumeDismiss: DispatchWorkItem?
  private weak var volumeWebView: WKWebView?
  private lazy var airPlayRoutes: AirPlayRouteController = {
    let routes = AirPlayRouteController()
    routes.willPresent = { [weak self] in
      self?.dismissSystemVolume()
      self?.updatePosition()
      self?.reportAirPlaySession("presenting")
    }
    routes.didDismiss = { [weak self] in self?.reportAirPlaySession("dismissed") }
    return routes
  }()

  /// 由系统处理设备发现和音频路由，不创建第二个播放器。
  @objc func airplay(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(AirPlayRouteRequest.self)
    DispatchQueue.main.async {
      guard let webview = self.volumeWebView else {
        invoke.reject("播放器尚未显示"); return
      }
      do { invoke.resolve(["visible": try self.airPlayRoutes.update(request, in: webview)]) }
      catch { invoke.reject(error.localizedDescription) }
    }
  }

  private func reportAirPlaySession(_ phase: String) {
    let session = AVAudioSession.sharedInstance()
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    trigger("airplaySession", data: [
      "phase": phase, "routePicker": "AVRoutePickerView",
      "state": snapshot()["state"] ?? "unknown", "mediaEnabled": mediaEnabled,
      "hasTitle": !(info[MPMediaItemPropertyTitle] as? String ?? "").isEmpty,
      "hasArtist": !(info[MPMediaItemPropertyArtist] as? String ?? "").isEmpty,
      "hasArtwork": info[MPMediaItemPropertyArtwork] != nil,
      "rate": (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 0,
      "category": session.category.rawValue,
      "routePolicy": Int(session.routeSharingPolicy.rawValue),
      "outputs": session.currentRoute.outputs.map { $0.portType.rawValue }
    ])
  }

  override func load(webview: WKWebView) {
    super.load(webview: webview)
    volumeWebView = webview
    DispatchQueue.main.async {
      self.visible = true; self.installControls()
      self.volumeView.showsRouteButton = false
      self.volumePanel.layer.cornerRadius = 18
      self.volumePanel.clipsToBounds = true
      self.volumePanel.accessibilityIdentifier = "splayer-system-volume"
      self.volumeLabel.textAlignment = .center
      self.volumeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      self.volumePanel.contentView.addSubview(self.volumeView)
      self.volumePanel.contentView.addSubview(self.volumeLabel)
      self.volumeOverlay.addSubview(self.volumePanel)
      self.volumeOverlay.addTarget(self, action: #selector(self.dismissSystemVolume), for: .touchUpInside)
      self.volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.volumeLabel.text = "\(Int((session.outputVolume * 100).rounded()))%"
          if self.visible { self.trigger("systemVolume", data: ["volume": Double(session.outputVolume)]) }
        }
      }
    }
    Task { @MainActor in
      SiriService.shared.changed = { [weak self] json in self?.trigger("siriQueue", data: ["json": json]) }
      SiriMediaHandler.install()
    }
  }

  @objc private func dismissSystemVolume() {
    volumeDismiss?.cancel()
    volumeOverlay.removeFromSuperview()
  }

  /// 使用系统原生音量控件，不修改系统音量浮层的私有接口。
  // Tauri 将前端 snake_case 命令转换为 camelCase 后查找 Objective-C 方法。
  @objc func systemVolume(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(SystemVolumeRequest.self)
    DispatchQueue.main.async {
      if request.show == false { self.dismissSystemVolume() }
      if request.show == true || request.value != nil {
        guard self.visible, let webview = self.volumeWebView, let window = webview.window else { invoke.reject("播放器尚未显示"); return }
        // 挂在当前窗口顶层，避免 WKWebView 的内容层或播放器全屏层覆盖原生控件。
        self.volumeOverlay.frame = window.bounds
        self.volumeOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let inset = window.safeAreaInsets
        let scaleX = webview.bounds.width / CGFloat(max(1, request.viewportWidth ?? Double(webview.bounds.width)))
        let scaleY = webview.bounds.height / CGFloat(max(1, request.viewportHeight ?? Double(webview.bounds.height)))
        let anchor = webview.convert(CGPoint(x: CGFloat(request.x ?? Double(webview.bounds.midX)) * scaleX,
          y: CGFloat(request.y ?? Double(webview.bounds.midY)) * scaleY), to: window)
        let width = min(240, window.bounds.width - inset.left - inset.right - 24)
        let x = min(max(anchor.x - width / 2, inset.left + 12), window.bounds.width - inset.right - width - 12)
        let y = min(max(anchor.y - 88, inset.top + 12), window.bounds.height - inset.bottom - 88)
        self.volumePanel.frame = CGRect(x: x, y: y, width: width, height: 76)
        self.volumeView.frame.size.width = width - 32
        self.volumeLabel.frame.size.width = width - 32
        window.addSubview(self.volumeOverlay)
        self.volumePanel.layoutIfNeeded()
        if let value = request.value {
          guard value.isFinite, (0...1).contains(value),
                let slider = self.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { invoke.reject("系统音量控件不可用"); return }
          slider.setValue(value, animated: false)
          slider.sendActions(for: .valueChanged)
        }
        self.volumeLabel.text = "\(Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded()))%"
        self.volumeDismiss?.cancel()
        let dismiss = DispatchWorkItem { [weak self] in self?.dismissSystemVolume() }
        self.volumeDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismiss)
      }
      invoke.resolve(["volume": Double(AVAudioSession.sharedInstance().outputVolume)])
    }
  }

  @objc func siri(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(SiriRequest.self)
    guard let value = try JSONSerialization.jsonObject(with: Data(request.request.utf8)) as? [String: Any] else {
      invoke.reject("无效的 Siri 请求"); return
    }
    Task { @MainActor in
      do {
        let result = try await SiriService.shared.command(value)
        let text = String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!
        invoke.resolve(["json": text])
      } catch { invoke.reject(error.localizedDescription) }
    }
  }

  @objc func readMetadata(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(SourceRequest.self)
    guard let url = request.source.hasPrefix("/") ? URL(fileURLWithPath: request.source) : URL(string: request.source), url.isFileURL else {
      invoke.reject("只读取用户导入的本地音频标签"); return
    }
    Task {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.commonMetadata)
        var value: JSObject = [:]
        for item in items {
          if let text = try? await item.load(.stringValue) {
            switch item.commonKey {
            case .commonKeyTitle: value["title"] = text
            case .commonKeyArtist: value["artist"] = text
            case .commonKeyAlbumName: value["album"] = text
            default: break
            }
          }
        }
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
          value["duration"] = max(0, duration.seconds * 1000)
        }
        invoke.resolve(value)
      } catch { invoke.reject("音频标签读取失败") }
    }
  }

  deinit {
    timer?.invalidate()
    loadTimeout?.cancel()
    artworkTask?.cancel()
    for (command, target) in remoteTargets { command.removeTarget(target) }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    player?.delegate = nil
    player?.stop()
  }

  /** 创建单个流式播放器，切歌后释放旧解码器与网络连接。 */
  @objc func load(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(SourceRequest.self)
    startSource(request.source, autoPlay: request.autoPlay, trackId: request.trackId) { result in
      switch result {
      case .success(let value): invoke.resolve(value)
      case .failure(let error): invoke.reject(error.localizedDescription)
      }
    }
  }

  func startSource(_ source: String, autoPlay: Bool, trackId: String?, completion: @escaping (Result<JSObject, Error>) -> Void) {
    let invoke = PlaybackCompletion(callback: completion)
    DispatchQueue.main.async {
      self.installControls()
      guard let url = source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(string: source),
            ["https", "http", "file"].contains(url.scheme ?? "") else {
        invoke.reject("原生播放器不支持该音源地址"); return
      }
      self.loadTimeout?.cancel()
      self.pendingLoad?.reject("已切换歌曲")
      self.pendingLoad = nil
      self.player?.delegate = nil
      self.player?.stop()
      self.player = nil
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
        let player = AudioPlayer()
        self.audioEffects = AudioEffects()
        player.attach(nodes: [self.audioEffects.equalizer, self.audioEffects.timePitch])
        self.player = player
        self.sourceURL = url
        self.currentTrackId = trackId
        self.autoPlay = autoPlay
        self.applyEffects()
        // 预载不应短暂漏出声音，缓冲完成后再恢复目标音量。
        if !autoPlay { player.volume = 0 }
        self.pendingLoad = invoke
        player.delegate = self
        player.play(url: url)
        let timeout = DispatchWorkItem { [weak self, weak player] in
          guard let self = self, self.player === player, let pending = self.pendingLoad else { return }
          self.pendingLoad = nil
          player?.stop()
          pending.reject("原生音频加载超时")
        }
        self.loadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
      } catch { invoke.reject(error.localizedDescription) }
    }
  }

  private func applyEffects() {
    guard let player = player else { return }
    audioEffects.apply(effects)
    player.volume = pendingLoad != nil && !autoPlay ? 0 : 1
    player.rate = effects.speed
    updatePosition()
  }

  @objc func configure(_ invoke: Invoke) throws {
    let value = try invoke.parseArgs(EffectRequest.self)
    guard value.bands.count == 10,
          value.bands.allSatisfy({ $0.isFinite && abs($0) <= 15 }),
          value.volume.isFinite, (0...1).contains(value.volume),
          value.speed.isFinite, (0.5...2).contains(value.speed),
          value.pitch.isFinite, abs(value.pitch) <= 12,
          value.preamp.isFinite, abs(value.preamp) <= 12 else {
      invoke.reject("音效参数超出范围"); return
    }
    DispatchQueue.main.async {
      self.effects = value
      if let data = try? JSONEncoder().encode(value) {
        UserDefaults.standard.set(data, forKey: "splayer.native.audio-effects")
      }
      self.applyEffects()
      invoke.resolve()
    }
  }

  @objc func control(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(ControlRequest.self)
    DispatchQueue.main.async {
      do { invoke.resolve(try self.performControl(request.action, position: request.position)) }
      catch { invoke.reject(error.localizedDescription) }
    }
  }

  func performControl(_ action: String, position: Double? = nil) throws -> JSObject {
      guard let player = self.player else { throw SiriFailure("请先选择一首歌曲") }
      switch action {
      case "play":
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { throw error }
        self.autoPlay = true
        if player.state == .stopped, let url = self.sourceURL { player.play(url: url) }
        else { player.resume() }
      case "pause":
        self.resumeAfterInterruption = false
        player.pause()
      case "stop":
        self.pendingLoad?.reject("播放已停止")
        self.pendingLoad = nil
        self.loadTimeout?.cancel()
        player.stop()
      case "seek":
        guard let ms = position, ms.isFinite, player.duration > 0 else {
          throw SiriFailure("当前音源暂不支持跳转")
        }
        player.seek(to: max(0, min(ms / 1000, player.duration)))
        Task { @MainActor in SiriService.shared.checkpoint() }
      default: throw SiriFailure("未知播放操作")
      }
      self.updatePosition()
      return self.snapshot()
  }

  func snapshot() -> JSObject {
    let state: String
    switch player?.state {
    case .playing, .running: state = "playing"
    case .paused: state = "paused"
    case .bufferring: state = "loading"
    case .stopped: state = "stopped"
    default: state = "idle"
    }
    return ["state": state, "position": (player?.progress ?? 0) * 1000,
      "duration": (player?.duration ?? 0) * 1000, "volume": Double(AVAudioSession.sharedInstance().outputVolume),
      "speed": Double(effects.speed), "isFinished": player?.stopReason == .eof]
  }

  @objc func status(_ invoke: Invoke) {
    DispatchQueue.main.async {
      var value = self.snapshot()
      let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      value["nowPlaying"] = [
        "title": info[MPMediaItemPropertyTitle] as? String ?? "",
        "artist": info[MPMediaItemPropertyArtist] as? String ?? ""
      ] as JSObject
      value["equalizer"] = [
        "enabled": self.audioEffects.equalizer.bands.allSatisfy { !$0.bypass },
        "bands": self.audioEffects.equalizer.bands.map { Double($0.gain) },
        "preamp": Double(self.audioEffects.equalizer.globalGain)
      ] as JSObject
      invoke.resolve(value)
    }
  }
  @objc func visibility(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(VisibilityRequest.self)
    DispatchQueue.main.async {
      self.visible = request.visible
      self.airPlayRoutes.setVisible(request.visible)
      if !request.visible {
        Task { @MainActor in SiriService.shared.checkpoint() }
        self.dismissSystemVolume()
      }
      invoke.resolve()
    }
  }

  private func updatePosition() {
    guard mediaEnabled else { return }
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    if let value = metadataValue {
      let time = (player?.progress ?? 0) * 1000 + (value.offset ?? 0)
      let line = value.dynamic == true ? value.lines?.last(where: { $0.start <= time }) : nil
      let text = line.flatMap { time < $0.end + 3000 ? $0.text : nil } ?? ""
      info[MPMediaItemPropertyTitle] = text.isEmpty ? value.title : text
      info[MPMediaItemPropertyArtist] = text.isEmpty ? value.artist : "\(value.title) - \(value.artist)"
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.progress ?? 0
    info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
    info[MPNowPlayingInfoPropertyIsLiveStream] = false
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    info[MPMediaItemPropertyPlaybackDuration] = player?.duration ?? 0
    info[MPNowPlayingInfoPropertyPlaybackRate] = player?.state == .playing ? effects.speed : 0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  @objc func metadata(_ invoke: Invoke) throws {
    let value = try invoke.parseArgs(MetadataRequest.self)
    DispatchQueue.main.async {
      self.setMetadata(value)
      invoke.resolve()
    }
  }

  func setSiriMetadata(_ track: [String: Any], enabled: Bool) {
    setMetadata(MetadataRequest(title: track["title"] as? String ?? "",
      artist: (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / "),
      album: (track["album"] as? [String: Any])?["name"] as? String ?? "",
      cover: track["coverOriginal"] as? String ?? track["cover"] as? String ?? "",
      enabled: enabled, dynamic: false, offset: nil, lines: nil))
  }

  private func setMetadata(_ value: MetadataRequest) {
      self.mediaEnabled = value.enabled
      self.metadataValue = value
      guard value.enabled else {
        self.artworkTask?.cancel()
        self.artworkURL = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        return
      }
      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      info[MPMediaItemPropertyTitle] = value.title
      info[MPMediaItemPropertyArtist] = value.artist
      info[MPMediaItemPropertyAlbumTitle] = value.album
      if value.cover != self.artworkURL {
        self.artworkTask?.cancel()
        self.artworkURL = value.cover
        info.removeValue(forKey: MPMediaItemPropertyArtwork)
        if #available(iOS 26.0, *) { StillArtwork.clear(from: &info) }
        if let url = URL(string: value.cover), ["https", "http"].contains(url.scheme ?? "") {
          self.artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
              guard let self = self, self.artworkURL == value.cover, self.mediaEnabled else { return }
              var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
              current[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
              if #available(iOS 26.0, *) { StillArtwork.install(image: image, id: value.cover, into: &current) }
              MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
          }
          self.artworkTask?.resume()
        }
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      self.updatePosition()
  }

  private func installControls() {
    guard timer == nil else { return }
    let center = MPRemoteCommandCenter.shared()
    for (command, action) in [(center.playCommand, "play"), (center.pauseCommand, "pause"),
                             (center.togglePlayPauseCommand, "toggle"),
                             (center.nextTrackCommand, "next"), (center.previousTrackCommand, "prev")] {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        guard let self = self, let player = self.player else { return .noSuchContent }
        DispatchQueue.main.async {
          if action == "play" || (action == "toggle" && player.state != .playing) {
            do { try AVAudioSession.sharedInstance().setActive(true) }
            catch { self.trigger("error", data: ["message": error.localizedDescription]); return }
            self.autoPlay = true
            if player.state == .stopped, let url = self.sourceURL { player.play(url: url) }
            else { player.resume() }
          }
          else if action == "pause" || action == "toggle" { self.resumeAfterInterruption = false; player.pause() }
          else {
            Task { @MainActor in
              if (!self.visible || SiriService.shared.managesCollection) && SiriService.shared.enabled && !SiriService.shared.queue.tracks.isEmpty {
                do { try await SiriService.shared.advance(action == "next" ? 1 : -1) }
                catch { self.trigger("error", data: ["message": error.localizedDescription]) }
              } else { self.trigger("action", data: ["type": action]) }
            }
          }
          self.updatePosition()
        }
        return .success
      }
      remoteTargets.append((command, target))
    }
    let seek = center.changePlaybackPositionCommand
    seek.isEnabled = true
    remoteTargets.append((seek, seek.addTarget { [weak self] event in
      guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent,
            let player = self.player, player.duration > 0 else { return .commandFailed }
      DispatchQueue.main.async {
        player.seek(to: event.positionTime); self.updatePosition()
        Task { @MainActor in SiriService.shared.checkpoint() }
      }
      return .success
    }))
    observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
      guard let self = self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if type == .began {
        self.resumeAfterInterruption = self.player?.state == .playing
        self.player?.pause()
      } else {
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        if self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
          do { try AVAudioSession.sharedInstance().setActive(true); self.player?.resume() }
          catch { self.trigger("error", data: ["message": error.localizedDescription]) }
        }
        self.resumeAfterInterruption = false
      }
    })
    observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
      if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        self?.player?.pause()
      }
    })
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      guard let self = self, self.player?.state == .playing else { return }
      // 后台动态歌词由原生时钟更新，不依赖 WebView 的定时器继续运行。
      if self.metadataValue?.dynamic == true && Date().timeIntervalSince(self.lastLyricUpdate) >= 1 {
        self.lastLyricUpdate = Date()
        self.updatePosition()
      }
      if self.visible { self.trigger("position", data: self.snapshot()) }
      if Date().timeIntervalSince(self.lastPlaybackCheckpoint) >= 5 {
        self.lastPlaybackCheckpoint = Date()
        Task { @MainActor in SiriService.shared.checkpoint() }
      }
    }
  }

  // 该回调在 waitingForData 阶段触发，此时既不能暂停下载，也不能宣布音源可跳转。
  func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {}
  func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
    DispatchQueue.main.async {
      guard self.player === player else { return }
      if newState == .playing, player.state == .playing, let pending = self.pendingLoad {
        self.loadTimeout?.cancel()
        if !self.autoPlay { player.pause(); player.volume = 1 }
        self.pendingLoad = nil
        pending.resolve(self.snapshot())
      }
      self.updatePosition()
      self.trigger("state", data: self.snapshot())
      if newState == .paused {
        Task { @MainActor in SiriService.shared.checkpoint() }
      }
    }
  }
  func audioPlayerDidFinishPlaying(player: AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
    guard stopReason == .eof else { return }
    DispatchQueue.main.async {
      if self.player === player {
        Task { @MainActor in
          if (!self.visible || SiriService.shared.managesCollection) && SiriService.shared.enabled && !SiriService.shared.queue.tracks.isEmpty {
            do { try await SiriService.shared.advance(1, ended: true) }
            catch { self.trigger("error", data: ["message": error.localizedDescription]) }
          } else { self.trigger("ended", data: [:]) }
        }
      }
    }
  }
  func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
    DispatchQueue.main.async {
      guard self.player === player else { return }
      self.loadTimeout?.cancel()
      if let pending = self.pendingLoad { pending.reject(error.localizedDescription); self.pendingLoad = nil }
      else { self.trigger("error", data: ["message": error.localizedDescription]) }
    }
  }
  func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId) {}
  func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}
  func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}
}

@_cdecl("init_plugin_native_audio")
func initNativeAudioPlugin() -> Plugin {
  Task { @MainActor in SiriMediaHandler.install() }
  return NativeAudioPlugin.shared
}
