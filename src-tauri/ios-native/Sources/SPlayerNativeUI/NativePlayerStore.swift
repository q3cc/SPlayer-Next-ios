import AVFoundation
import Combine
import Foundation

#if os(iOS)
  import MediaPlayer
#endif

/// 播放状态来自 AVPlayer，不以按钮点击伪造播放成功。
@MainActor
public final class NativePlayerStore: ObservableObject {
  @Published public private(set) var tracks: [NativeTrack] = []
  @Published public private(set) var queue: [NativeTrack] = []
  @Published public private(set) var current: NativeTrack?
  @Published public private(set) var isPlaying = false
  @Published public private(set) var positionMs = 0.0
  @Published public private(set) var durationMs = 0.0
  @Published public private(set) var importing = false
  @Published public private(set) var lyrics: [NativeLyricLine] = []
  @Published public var error: String?
  @Published public var repeatOne = false
  @Published var shuffle = false
  var positionAnchor = Date()
  private var resumePosition: Double?
  @Published public private(set) var favoriteTracks: [NativeTrack] = []
  @Published private(set) var bookmarks: [NativeCover] = []
  @Published var selectedPlaylistID: String?
  @Published private(set) var playlists: [NativePlaylist] = []
  @Published public private(set) var history: [NativeTrack] = []
  @Published public private(set) var loadingTrack: String?
  let service = NativeOnlineService()
  lazy var plugins = NativePluginStore(root: root, player: self)
  lazy var catalog = NativeCatalogStore(service: service)
  private var playbackTask: Task<Void, Never>?
  private var generation = 0
  private var lastCheckpoint = Date.distantPast
  private var restored = false
  public var title: String { current?.title ?? "未在播放" }
  public var artist: String { current?.artist ?? "选择一首歌曲开始播放" }
  public var progress: Double { durationMs > 0 ? min(1, positionMs / durationMs) : 0 }
  private let library: NativeLibrary
  private let root: URL
  private let engine = AVPlayer()
  private var timeObserver: Any?
  private var stateObserver: NSKeyValueObservation?
  private var itemObserver: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var routeObserver: NSObjectProtocol?
  private var resumeAfterInterruption = false
  private var interfaceActive = true
  #if os(iOS)
    private var commands: [(MPRemoteCommand, Any)] = []
  #endif

  /// 连接真实音频引擎、进度观察和系统媒体控制
  public init(root: URL = NativeLibrary.defaultRoot()) {
    self.root = root
    library = NativeLibrary(root: root)
    stateObserver = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isPlaying = self.engine.timeControlStatus == .playing
        self.publishNowPlaying()
      }
    }
    timeObserver = engine.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self, self.interfaceActive, self.engine.currentItem != nil else { return }
        self.positionAnchor = Date()
        self.positionMs = time.seconds.isFinite ? max(0, time.seconds * 1000) : 0
        let duration = self.engine.currentItem?.duration.seconds ?? 0
        if duration.isFinite { self.durationMs = max(0, duration * 1000) }
        if self.isPlaying && Date().timeIntervalSince(self.lastCheckpoint) >= 5 {
          self.persistPlayback()
          self.lastCheckpoint = Date()
        }
      }
    }
    #if os(iOS)
      installRemoteCommands()
    #endif
  }

  deinit {
    if let timeObserver { engine.removeTimeObserver(timeObserver) }
    for observer in [endObserver, interruptionObserver, routeObserver].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(observer)
    }
    #if os(iOS)
      for (command, target) in commands { command.removeTarget(target) }
    #endif
  }

  /// 恢复曲库、收藏和队列，不自动开始播放
  public func loadLibrary() async {
    do {
      tracks = try await library.load()
      playlists = try await library.loadPlaylists()
      bookmarks = try await library.loadBookmarks()
      plugins.load()
      if !restored {
        let saved = try await library.loadPlayback()
        queue = saved.queue
        favoriteTracks = saved.favorites
        history = saved.history
        current = queue.first { $0.id == saved.currentID }
        durationMs = current?.durationMs ?? 0
        positionMs = saved.positionMs
        restored = true
      }
    } catch { self.error = "无法读取曲库：" + error.localizedDescription }
  }

  /// 前台恢复实时进度，后台停止界面高频更新
  public func setInterfaceActive(_ active: Bool) {
    interfaceActive = active
    if active, engine.currentItem != nil {
      positionAnchor = Date()
      let seconds = engine.currentTime().seconds
      positionMs = seconds.isFinite ? max(0, seconds * 1000) : 0
      isPlaying = engine.timeControlStatus == .playing
    }
  }

  /// 顺序导入用户选择的文件并汇总失败信息
  public func importFiles(_ urls: [URL]) async {
    guard !importing else { return }
    importing = true
    defer { importing = false }
    var failures: [String] = []
    for url in urls {
      do { tracks.append(try await library.importFile(url)) } catch {
        failures.append(url.lastPathComponent + "：" + error.localizedDescription)
      }
    }
    if !failures.isEmpty { error = failures.prefix(5).joined(separator: "\n") }
  }

  /// 删除应用内记录和副本，保留用户原始文件
  public func remove(_ track: NativeTrack) async {
    do {
      try await library.remove(track)
      if current?.id == track.id { stop() }
      tracks.removeAll { $0.id == track.id }
      queue.removeAll { $0.id == track.id }
      favoriteTracks.removeAll { $0.id == track.id }
      history.removeAll { $0.id == track.id }
      for index in playlists.indices { playlists[index].tracks.removeAll { $0.id == track.id } }
      persistPlaylists()
      persistPlayback()
    } catch { self.error = "无法删除歌曲：" + error.localizedDescription }
  }

  /// 先解析在线音源，再切换原生播放器；旧请求永远不能覆盖新的选曲
  public func play(_ track: NativeTrack, in tracks: [NativeTrack]? = nil) {
    generation += 1
    let token = generation
    playbackTask?.cancel()
    loadingTrack = nil
    if let tracks { queue = tracks }
    if !queue.contains(where: { $0.id == track.id }) { queue.append(track) }
    if track.source != nil, let payload = track.platformTrack {
      loadingTrack = track.id
      playbackTask = Task {
        do {
          let result: [String: Any]?
          if let customURL = try await plugins.resolve(track) {
            result = ["url": customURL, "isTrial": false]
          } else {
            result =
              try await service.call([
                "action": "resolve", "source": track.source!, "track": payload,
              ]) as? [String: Any]
          }
          guard generation == token, !Task.isCancelled else { return }
          guard let text = result?["url"] as? String, let url = URL(string: text),
            ["https", "http"].contains(url.scheme ?? ""), result?["isTrial"] as? Bool != true
          else {
            throw SiriFailure("未获取到可完整播放的音源")
          }
          start(track, url: url)
          loadingTrack = nil
          if let response = try? await service.call(["action": "lyrics", "track": payload])
            as? [String: Any],
            generation == token, current?.id == track.id,
            let lines = response["lines"],
            let data = try? JSONSerialization.data(withJSONObject: lines)
          {
            lyrics = (try? JSONDecoder().decode([NativeLyricLine].self, from: data)) ?? []
          }
        } catch is CancellationError {} catch {
          if generation == token {
            loadingTrack = nil
            self.error = error.localizedDescription
          }
        }
      }
    } else {
      let url = root.appendingPathComponent(track.fileName)
      guard FileManager.default.fileExists(atPath: url.path) else {
        error = "无法播放：本地文件不存在"
        return
      }
      start(track, url: url)
    }
  }

  /// 音源就绪后启动 AVPlayer，播放状态只由引擎回调提供
  private func start(_ track: NativeTrack, url: URL) {
    do {
      #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(
          .playback, mode: .default, policy: .longFormAudio)
        try AVAudioSession.sharedInstance().setActive(true)
      #endif
      if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
      let item = AVPlayerItem(url: url)
      itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        Task { @MainActor [weak self] in
          guard let self, self.engine.currentItem === item, item.status == .failed else { return }
          self.error = item.error?.localizedDescription ?? "无法播放此文件"
          self.engine.pause()
        }
      }
      endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if self.repeatOne {
            self.seek(to: 0)
            self.engine.play()
          } else {
            self.next()
          }
        }
      }
      current = track
      history.removeAll { $0.id == track.id }
      history.insert(track, at: 0)
      history = Array(history.prefix(100))
      lyrics = []
      positionMs = 0
      positionAnchor = Date()
      durationMs = track.durationMs
      engine.replaceCurrentItem(with: item)
      if let resumePosition {
        seek(to: resumePosition)
        self.resumePosition = nil
      }
      engine.play()
      publishNowPlaying()
      persistPlayback()
      Task {
        let raw = (try? await library.lyrics(for: track)) ?? ""
        if current?.id == track.id { lyrics = NativeLyricLine.parse(raw) }
      }
    } catch { self.error = "无法播放：" + error.localizedDescription }
  }

  /// 切换真实引擎状态，必要时先恢复持久队列的音源
  public func togglePlayback() {
    if loadingTrack != nil {
      generation += 1
      playbackTask?.cancel()
      loadingTrack = nil
      engine.pause()
      return
    }
    guard let current else { return }
    if engine.currentItem == nil {
      resumePosition = positionMs
      play(current)
      return
    }
    if engine.timeControlStatus == .paused { engine.play() } else { engine.pause() }
  }

  /// 按毫秒定位并限制在曲目时长内，同时保存恢复位置
  public func seek(to milliseconds: Double) {
    guard milliseconds.isFinite else { return }
    let value = min(max(0, milliseconds), durationMs)
    engine.seek(to: CMTime(seconds: value / 1000, preferredTimescale: 600))
    positionMs = value
    positionAnchor = Date()
    publishNowPlaying()
    persistPlayback()
  }

  /// 按随机或列表顺序选择下一首曲目
  public func next() {
    guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
    if shuffle, let track = queue.filter({ $0.id != id }).randomElement() {
      play(track)
    } else if index + 1 < queue.count {
      play(queue[index + 1])
    } else if let first = queue.first {
      play(first)
    }
  }

  /// 已播放超过三秒时回到开头，否则切换上一首
  public func previous() {
    guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
    if positionMs > 3000 || index == 0 { seek(to: 0) } else { play(queue[index - 1]) }
  }

  /// 应用系统拖放索引并保存新队列顺序
  public func moveQueue(from offsets: IndexSet, to destination: Int) {
    let selected = offsets.sorted().map { queue[$0] }
    for index in offsets.sorted(by: >) { queue.remove(at: index) }
    queue.insert(contentsOf: selected, at: destination - offsets.filter { $0 < destination }.count)
    persistPlayback()
  }

  /// 只移除待播记录，不删除曲库文件
  public func removeQueue(at offsets: IndexSet) {
    for index in offsets.sorted(by: >) { queue.remove(at: index) }
    persistPlayback()
  }

  /// 读取用户授权的歌词文件并保存到当前曲目
  public func importLyrics(_ url: URL) async {
    guard let track = current else { return }
    do {
      let text = try await library.importLyrics(url, for: track)
      if current?.id == track.id { lyrics = NativeLyricLine.parse(text) }
    } catch { self.error = "无法导入歌词：" + error.localizedDescription }
  }

  /// 收藏在线曲目时同时保存曲目元数据，重启后无需重新搜索
  func toggleFavorite(_ track: NativeTrack) {
    if favoriteTracks.contains(where: { $0.id == track.id }) {
      favoriteTracks.removeAll { $0.id == track.id }
    } else {
      favoriteTracks.append(track)
    }
    persistPlayback()
  }

  /// 追加待播曲目，不改变当前音频状态
  func enqueue(_ track: NativeTrack) {
    if !queue.contains(where: { $0.id == track.id }) { queue.append(track) }
    persistPlayback()
  }

  /// 收藏推荐歌单后可从侧栏重新打开，不改变平台账号的收藏
  func toggleBookmark(_ cover: NativeCover) {
    if bookmarks.contains(where: { $0.id == cover.id }) {
      bookmarks.removeAll { $0.id == cover.id }
    } else {
      bookmarks.append(cover)
    }
    let values = bookmarks
    Task {
      do { try await library.saveBookmarks(values) } catch {
        self.error = error.localizedDescription
      }
    }
  }

  /// 新歌单使用稳定身份，名称校验后持久化
  func createPlaylist(_ name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 100 else {
      error = "歌单名称需要 1–100 个字"
      return
    }
    let value = NativePlaylist(id: UUID().uuidString, name: name, tracks: [])
    playlists.append(value)
    selectedPlaylistID = value.id
    persistPlaylists()
  }
  /// 用户确认后仅移除歌单，不删除音乐文件
  func deletePlaylist(_ id: String) {
    playlists.removeAll { $0.id == id }
    if selectedPlaylistID == id { selectedPlaylistID = nil }
    persistPlaylists()
  }
  /// 添加已有曲目，保留来源元数据并去除重复项
  func addToPlaylist(_ id: String, track: NativeTrack) {
    guard let index = playlists.firstIndex(where: { $0.id == id }),
      !playlists[index].tracks.contains(where: { $0.id == track.id })
    else { return }
    playlists[index].tracks.append(track)
    persistPlaylists()
  }
  /// 曲目从歌单移除不影响曲库或其他歌单
  func removeFromPlaylist(_ id: String, track: NativeTrack) {
    guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
    playlists[index].tracks.removeAll { $0.id == track.id }
    persistPlaylists()
  }
  /// 在曲库 actor 中保存当前歌单快照
  private func persistPlaylists() {
    let values = playlists
    Task {
      do { try await library.savePlaylists(values) } catch {
        self.error = error.localizedDescription
      }
    }
  }

  /// 后台保存发生在曲库 actor，快照捕获当前状态避免乱序读取
  private func persistPlayback() {
    let value = NativePlaybackState(
      queue: queue, currentID: current?.id, positionMs: positionMs,
      favorites: favoriteTracks, history: history)
    Task {
      do { try await library.savePlayback(value) } catch {
        self.error = "保存播放记录失败：" + error.localizedDescription
      }
    }
  }

  /// 经宿主权限和共享参数校验后执行播放控制，不接受插件指定的本地路径
  func pluginControl(_ method: String, args: [Any]) throws -> Any {
    switch method {
    case "player.play": if !isPlaying { togglePlayback() }
    case "player.pause": engine.pause()
    case "player.stop": stop()
    case "player.next": next()
    case "player.prev": previous()
    case "player.seek": seek(to: args[0] as! Double)
    case "player.setVolume": engine.volume = Float(args[0] as! Double)
    case "player.getPosition": return positionMs
    case "player.getStatus":
      return [
        "state": current == nil ? "stopped" : isPlaying ? "playing" : "paused",
        "positionMs": positionMs, "durationMs": durationMs, "volume": engine.volume,
        "isFinished": false, "currentIndex": queue.firstIndex { $0.id == current?.id } ?? -1,
        "repeat": repeatOne ? "one" : "list", "shuffle": shuffle ? "on" : "off",
      ] as [String: Any]
    case "player.getNowPlaying":
      return [
        "track": current?.sharedTrack as Any? ?? NSNull(), "position": positionMs,
        "playing": isPlaying,
        "state": current == nil ? "stopped" : isPlaying ? "playing" : "paused", "speed": 1,
        "lyricOffsetMs": 0, "sendTimestamp": Date().timeIntervalSince1970 * 1000,
        "lyricAvailable": !lyrics.isEmpty, "lyricLineCount": lyrics.count,
      ] as [String: Any]
    case "player.getQueue":
      let query = args[0] as! [String: Any]
      let offset = query["offset"] as! Int
      let limit = query["limit"] as! Int
      return [
        "tracks": Array(queue.dropFirst(offset).prefix(limit)).map(\.sharedTrack),
        "total": queue.count, "currentIndex": queue.firstIndex { $0.id == current?.id } ?? -1,
        "offset": offset,
      ]
    case "player.playTrack":
      let value = args[0] as! [String: Any]
      let track = try pluginTrack(value)
      play(track)
      return ["id": value["id"]!, "source": value["source"]!]
    case "player.addToQueue":
      let values = args[0] as! [[String: Any]]
      let tracks = try values.map(pluginTrack)
      let index =
        (args[1] as! String) == "next"
        ? (queue.firstIndex { $0.id == current?.id }.map { $0 + 1 } ?? queue.count) : queue.count
      queue.insert(contentsOf: tracks, at: index)
      persistPlayback()
      return ["count": tracks.count]
    case "player.setPlayMode":
      let mode = args[0] as! [String: Any]
      if let value = mode["repeat"] as? String { repeatOne = value == "one" }
      if let value = mode["shuffle"] as? String { shuffle = value == "on" }
    default: throw SiriFailure("未知播放操作")
    }
    return NSNull()
  }

  /// 本地曲目只按已有 ID 查找，禁止脚本构造任意文件路径
  private func pluginTrack(_ value: [String: Any]) throws -> NativeTrack {
    if value["source"] as? String == "local",
      let track = tracks.first(where: { $0.id == value["id"] as? String })
    {
      return track
    }
    guard ["netease", "qqmusic", "kugou", "plugin"].contains(value["source"] as? String ?? ""),
      let track = NativeTrack.online(value)
    else { throw SiriFailure("此曲目不在原生曲库或不支持该来源") }
    return track
  }

  /// 取消在途解析并停止引擎，避免旧请求恢复播放
  func stop() {
    generation += 1
    playbackTask?.cancel()
    loadingTrack = nil
    engine.pause()
    engine.replaceCurrentItem(with: nil)
    current = nil
    lyrics = []
    positionMs = 0
    durationMs = 0
    resumePosition = nil
    publishNowPlaying()
    persistPlayback()
  }

  /// 把当前曲目与引擎状态同步给系统媒体控件
  private func publishNowPlaying() {
    #if os(iOS)
      guard let current else {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        return
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
        MPMediaItemPropertyPlaybackDuration: durationMs / 1000,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: positionMs / 1000,
        MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
      ]
    #endif
  }

  #if os(iOS)
    /// 连接锁屏媒体命令、音频中断与耳机断开事件
    private func installRemoteCommands() {
      let center = MPRemoteCommandCenter.shared()
      let actions: [(MPRemoteCommand, @MainActor () -> Void)] = [
        (center.playCommand, { [weak self] in self?.engine.play() }),
        (center.pauseCommand, { [weak self] in self?.engine.pause() }),
        (center.nextTrackCommand, { [weak self] in self?.next() }),
        (center.previousTrackCommand, { [weak self] in self?.previous() }),
      ]
      for (command, action) in actions {
        let target = command.addTarget { _ in
          Task { @MainActor in action() }
          return .success
        }
        commands.append((command, target))
      }
      let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else {
          return .commandFailed
        }
        Task { @MainActor [weak self] in self?.seek(to: event.positionTime * 1000) }
        return .success
      }
      commands.append((center.changePlaybackPositionCommand, target))
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        Task { @MainActor [weak self] in
          guard let self, let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
          else { return }
          if type == AVAudioSession.InterruptionType.began.rawValue {
            self.resumeAfterInterruption = self.isPlaying
            self.engine.pause()
          } else {
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if self.resumeAfterInterruption
              && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            {
              self.engine.play()
            }
            self.resumeAfterInterruption = false
          }
        }
      }
      routeObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard
          note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        else { return }
        Task { @MainActor [weak self] in self?.engine.pause() }
      }
    }
  #endif
}
