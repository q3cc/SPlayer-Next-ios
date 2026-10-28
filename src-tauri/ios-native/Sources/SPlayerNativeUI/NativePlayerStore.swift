import AVFoundation
import Combine
import Foundation

#if os(iOS)
  import MediaPlayer
#endif

/// 播放状态来自 Next iOS 的 AudioStreaming 引擎，不以按钮点击伪造播放成功
@MainActor
public final class NativePlayerStore: ObservableObject {
  @Published public private(set) var tracks: [NativeTrack] = []
  @Published public private(set) var queue: [NativeTrack] = []
  @Published private(set) var playbackContext: String?
  @Published public private(set) var current: NativeTrack? {
    didSet { if oldValue?.id != current?.id { playStats.trackChanged(current, playing: isPlaying) } }
  }
  @Published public private(set) var isPlaying = false {
    didSet { if oldValue != isPlaying { playStats.playingChanged(isPlaying) } }
  }
  @Published public private(set) var positionMs = 0.0
  @Published public private(set) var durationMs = 0.0
  @Published public private(set) var importing = false
  @Published private(set) var rawLyrics: String?
  @Published public private(set) var lyrics: [NativeLyricLine] = []
  /// 歌词格式（yrc / qrc / krc / ttml / lrc …），播放页标签与原版一样显示真实格式
  @Published private(set) var lyricFormat: String?
  @Published public var error: String?
  /// 非错误的轻提示，例如“已加入下载”
  @Published var notice: String?
  @Published public var repeatOne = false
  @Published var showOriginalLyrics = true
  @Published var shuffle = false
  @Published var speed = 1.0 {
    didSet {
      engine.rate = Float(speed)
      positionAnchor = Date()
      publishNowPlaying()
    }
  }
  @Published var fadeEnabled =
    UserDefaults.standard.object(forKey: "native.player.fade") as? Bool ?? true
  {
    didSet {
      UserDefaults.standard.set(fadeEnabled, forKey: "native.player.fade")
      applyProcessing()
    }
  }
  @Published var fadeDuration =
    UserDefaults.standard.object(forKey: "native.player.fadeDuration") as? Double ?? 200
  {
    didSet {
      UserDefaults.standard.set(fadeDuration, forKey: "native.player.fadeDuration")
      applyProcessing()
    }
  }
  @Published var loudnessNormalization = UserDefaults.standard.bool(
    forKey: "native.player.normalization")
  {
    didSet {
      UserDefaults.standard.set(loudnessNormalization, forKey: "native.player.normalization")
      applyProcessing()
    }
  }
  @Published var mediaControls =
    UserDefaults.standard.object(forKey: "native.media.controls") as? Bool ?? true
  {
    didSet {
      UserDefaults.standard.set(mediaControls, forKey: "native.media.controls")
      publishNowPlaying()
    }
  }
  @Published var dynamicLyrics = UserDefaults.standard.bool(forKey: "native.media.dynamicLyrics") {
    didSet {
      UserDefaults.standard.set(dynamicLyrics, forKey: "native.media.dynamicLyrics")
      publishNowPlaying()
    }
  }
  /// 音效开关直接作用于唯一音频引擎，不依赖播放器页面是否打开
  private func applyProcessing() {
    engine.fadeDuration = fadeEnabled ? fadeDuration : 0
    engine.normalization = loudnessNormalization
  }
  @Published var pitch = 0.0 { didSet { engine.pitch = Float(pitch) } }
  @Published var pitchSync = true { didSet { engine.pitchSync = pitchSync } }
  @Published var equalizer = NativeEqualizer.load() {
    didSet {
      applyEqualizer()
      if let data = try? JSONEncoder().encode(equalizer) {
        UserDefaults.standard.set(data, forKey: "native.player.equalizer")
      }
    }
  }
  /// 所有均衡器入口共用实际音频节点与持久参数
  private func applyEqualizer() {
    engine.eqEnabled = equalizer.enabled
    engine.bands = equalizer.bands.map(Float.init)
    engine.preamp = Float(equalizer.preamp)
  }
  private var lyricOffsets = NativeLyricOffsets.load()
  @Published var lyricOffsetMs = 0.0 {
    didSet { if let current { lyricOffsets.set(lyricOffsetMs, for: current.id) } }
  }
  @Published var pointA: Double? { didSet { updateABLoop() } }
  @Published var pointB: Double? { didSet { updateABLoop() } }
  @Published var abEnabled = false { didSet { updateABLoop() } }
  @Published private(set) var sleepDeadline: Date?
  @Published var sleepDuration = 30.0
  @Published var sleepWaitSongEnd = false
  @Published private(set) var waitingForSongEnd = false
  private var sleepTask: Task<Void, Never>?
  private var boundaryObserver: Timer?
  var validAB: Bool {
    if let pointA, let pointB { return pointB > pointA }
    return false
  }

  /// AB 使用独立时钟检查真实引擎位置，不依赖界面可见性
  private func updateABLoop() {
    boundaryObserver?.invalidate()
    boundaryObserver = nil
    if abEnabled && !validAB {
      abEnabled = false
      return
    }
    guard abEnabled, validAB else { return }
    boundaryObserver = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.engine.playing, let a = self.pointA, let b = self.pointB,
          self.engine.position >= b
        else { return }
        self.seek(to: a)
      }
    }
  }
  /// 定时到点暂停；重新设定或取消时撤销旧任务
  func setSleepTimer(minutes: Int?) {
    guard minutes == nil || (1...180).contains(minutes!) else { return }
    sleepTask?.cancel()
    waitingForSongEnd = false
    sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
    guard let minutes else {
      sleepTask = nil
      return
    }
    sleepTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000) } catch { return }
      guard let self else { return }
      if self.sleepWaitSongEnd {
        self.waitingForSongEnd = true
      } else {
        self.engine.pause()
        self.sleepDeadline = nil
      }
    }
  }
  @Published private(set) var bassVolume = 0.1
  let spectrumFrames = NativeSpectrumFrames()
  private var spectrum: NativeAudioSpectrum?
  private var spectrumTimer: Timer?
  private var spectrumRequested = false
  private var bassPulse = 0.0

  /// 仅可见播放器需要节拍时安装 tap；关闭会取消安装并移除音频混合器
  func setSpectrumActive(_ active: Bool) {
    spectrumRequested = active
    spectrumTimer?.invalidate()
    spectrumTimer = nil
    engine.setAnalysis(nil)
    spectrum = nil
    bassPulse = 0
    bassVolume = 0.1
    guard active, engine.loaded else { return }
    let analyzer = NativeAudioSpectrum()
    spectrum = analyzer
    engine.setAnalysis(analyzer)
    spectrumTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.isPlaying, let frame = self.spectrum?.consume() else { return }
        self.spectrumFrames.push(frame)
        let pulse = NativeAudioSpectrum.pulse(frame)
        self.bassPulse += (pulse > self.bassPulse ? 0.45 : 0.14) * (pulse - self.bassPulse)
        self.bassVolume = (1 + self.bassPulse * 2.4) / 10
      }
    }
  }
  var positionAnchor = Date()
  /// 后台不刷新 positionMs，歌词小窗等实时消费者直接读取引擎进度
  var livePositionMs: Double { engine.loaded ? engine.position : positionMs }
  lazy var lyricPiP = NativeLyricPiP(player: self)
  lazy var playStats = NativePlayStats(root: root)
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
  lazy var account = NativeAccountStore(service: service)
  lazy var downloads = NativeDownloadStore(
    root: root,
    exports: root.deletingLastPathComponent().appendingPathComponent(
      NativeDownloadStore.exportFolder, isDirectory: true), service: service, player: self)
  private var playbackTask: Task<Void, Never>?
  private var generation = 0
  private var lastCheckpoint = Date.distantPast
  private var restored = false
  public var title: String { current?.title ?? "未在播放" }
  public var artist: String { current?.artist ?? "选择一首歌曲开始播放" }
  public var progress: Double { durationMs > 0 ? min(1, positionMs / durationMs) : 0 }
  private let library: NativeLibrary
  private let root: URL
  private let engine = NativeAudioEngine()
  private var timeObserver: Timer?
  private var interruptionObserver: NSObjectProtocol?
  private var routeObserver: NSObjectProtocol?
  private var resumeAfterInterruption = false
  private var interfaceActive = true
  private var publishedLyricID: Int?
  #if os(iOS)
    private var commands: [(MPRemoteCommand, Any)] = []
  #endif

  /// 连接真实音频引擎、进度观察和系统媒体控制
  public init(root: URL = NativeLibrary.defaultRoot()) {
    self.root = root
    library = NativeLibrary(root: root)
    applyEqualizer()
    applyProcessing()
    engine.onState = { [weak self] in
      guard let self else { return }
      self.isPlaying = self.engine.playing
      self.publishNowPlaying()
    }
    engine.onError = { [weak self] message in self?.error = message }
    engine.onEnded = { [weak self] in
      guard let self else { return }
      self.playStats.trackEnded()
      if self.waitingForSongEnd {
        self.engine.pause()
        self.setSleepTimer(minutes: nil)
        return
      }
      if self.repeatOne && !self.fmMode, let current = self.current {
        self.load(current)
      } else {
        self.next()
      }
    }
    timeObserver = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.engine.loaded else { return }
        if self.dynamicLyrics && self.mediaControls
          && self.dynamicLyric(at: self.engine.position)?.id != self.publishedLyricID
        {
          self.publishNowPlaying()
        }
        guard self.interfaceActive else { return }
        let position = self.engine.position
        let duration = self.engine.duration
        if self.isPlaying || abs(position - self.positionMs) > 0.5 {
          self.positionAnchor = Date()
          self.positionMs = position
        }
        if duration > 0 && abs(duration - self.durationMs) > 0.5 { self.durationMs = duration }
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
    spectrumTimer?.invalidate()
    sleepTask?.cancel()
    boundaryObserver?.invalidate()
    timeObserver?.invalidate()
    for observer in [interruptionObserver, routeObserver].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(observer)
    }
    #if os(iOS)
      for (command, target) in commands { command.removeTarget(target) }
    #endif
  }

  /// 恢复曲库、收藏、队列和上次歌曲；记忆进度决定起播位置，仅用户启用自动播放时恢复音频
  public func loadLibrary() async {
    do {
      await playStats.load()
      tracks = try await library.load()
      playlists = try await library.loadPlaylists()
      bookmarks = try await library.loadBookmarks()
      plugins.load()
      downloads.load()
      if !restored {
        let saved = try await library.loadPlayback()
        queue = saved.queue
        playbackContext = saved.playbackContext
        favoriteTracks = saved.favorites
        history = saved.history
        let remember =
          UserDefaults.standard.object(forKey: "native.player.remember") as? Bool ?? true
        current = queue.first { $0.id == saved.currentID }
        if let current { lyricOffsetMs = lyricOffsets.value(for: current.id) }
        durationMs = current?.durationMs ?? 0
        positionMs = current != nil && remember ? saved.positionMs : 0
        restored = true
        if UserDefaults.standard.bool(forKey: "native.player.autoPlay"), current != nil {
          togglePlayback()
        }
      }
    } catch { self.error = "无法读取曲库：" + error.localizedDescription }
  }

  /// 前台恢复实时进度，后台停止界面高频更新
  public func setInterfaceActive(_ active: Bool) {
    interfaceActive = active
    if !active { playStats.checkpoint() }
    if active, engine.loaded {
      positionAnchor = Date()
      let seconds = engine.position / 1000
      positionMs = seconds.isFinite ? max(0, seconds * 1000) : 0
      isPlaying = engine.playing
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
  /// 与原版一致：手动选曲退出私人 FM，替换播放列表同时退出心动模式
  public func play(_ track: NativeTrack, in tracks: [NativeTrack]? = nil, context: String? = nil) {
    fmMode = false
    if let tracks {
      heartMode = false
      queue = tracks
      playbackContext = context
    }
    if !queue.contains(where: { $0.id == track.id }) { queue.append(track) }
    load(track)
  }

  /// 读取曲库文件大小，供统计页的总大小使用
  /// @returns 曲目 id 到文件字节数
  func librarySizes() async -> [String: Int64] {
    let files = tracks.map { ($0.id, root.appendingPathComponent($0.fileName).path) }
    return await Task.detached(priority: .utility) {
      var sizes: [String: Int64] = [:]
      for (id, path) in files {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber
        if let size { sizes[id] = size.int64Value }
      }
      return sizes
    }.value
  }

  /// 只播放这一首：插入当前曲目之后并立即播放，不替换播放列表；对应原版 playNow
  /// @param track - 要播放的曲目
  /// @param context - 播放来源说明
  func playNow(_ track: NativeTrack, context: String? = nil) {
    if current?.id == track.id, engine.loaded {
      if !engine.playing { engine.play() }
      return
    }
    fmMode = false
    queue.removeAll { $0.id == track.id }
    let index = current.flatMap { item in queue.firstIndex { $0.id == item.id } }
    queue.insert(track, at: index.map { $0 + 1 } ?? queue.count)
    if queue.count == 1 { playbackContext = context }
    load(track)
  }

  /// 解析音源并加载；私人 FM 使用独立曲池，不改动播放队列
  private func load(_ track: NativeTrack) {
    generation += 1
    let token = generation
    playbackTask?.cancel()
    loadingTrack = nil
    if track.source != nil, let payload = track.platformTrack {
      loadingTrack = track.id
      playbackTask = Task {
        do {
          let url = try await resolveURL(
            track, quality: UserDefaults.standard.string(forKey: "native.player.quality") ?? "hq")
          guard generation == token, !Task.isCancelled else { return }
          start(track, url: url)
          loadingTrack = nil
          if let response = try? await service.call(["action": "lyrics", "track": payload])
            as? [String: Any],
            generation == token, current?.id == track.id,
            let lines = response["lines"],
            let data = try? JSONSerialization.data(withJSONObject: lines)
          {
            lyrics = (try? JSONDecoder().decode([NativeLyricLine].self, from: data)) ?? []
            rawLyrics = response["raw"] as? String
            lyricFormat = response["format"] as? String
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

  /// 自定义音源优先，其次共享平台解析；试听片段视为不可用，播放与下载共用
  func resolveURL(_ track: NativeTrack, quality: String) async throws -> URL {
    guard let source = track.source, let payload = track.platformTrack else {
      throw SiriFailure("本地歌曲无需解析音源")
    }
    let result: [String: Any]?
    if let customURL = try await plugins.resolve(track) {
      result = ["url": customURL, "isTrial": false]
    } else {
      result =
        try await service.call([
          "action": "resolve", "source": source, "track": payload, "quality": quality,
        ]) as? [String: Any]
    }
    guard let text = result?["url"] as? String, let url = URL(string: text),
      ["https", "http"].contains(url.scheme ?? ""), result?["isTrial"] as? Bool != true
    else {
      throw SiriFailure("未获取到可完整播放的音源")
    }
    return url
  }

  /// 下载完成的文件加入应用曲库，之后可离线播放
  func registerDownload(
    file: URL, format: String, track: NativeTrack, cover: Data?, lyrics: String
  ) async throws -> NativeTrack {
    let added = try await library.addDownloaded(
      file: file, format: format, track: track, cover: cover, lyrics: lyrics)
    tracks.append(added)
    return added
  }

  /// 音源就绪后启动原生解码引擎，播放状态只由引擎回调提供
  private func start(_ track: NativeTrack, url: URL) {
    do {
      #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(
          .playback, mode: .default, policy: .longFormAudio)
        try AVAudioSession.sharedInstance().setActive(true)
      #endif
      if current?.id != track.id {
        abEnabled = false
        pointA = nil
        pointB = nil
      }
      current = track
      lyricOffsetMs = lyricOffsets.value(for: track.id)
      history.removeAll { $0.id == track.id }
      history.insert(track, at: 0)
      history = Array(history.prefix(100))
      lyrics = []
      rawLyrics = nil
      lyricFormat = nil
      positionMs = 0
      positionAnchor = Date()
      durationMs = track.durationMs
      engine.load(url)
      if spectrumRequested { setSpectrumActive(true) }
      if let resumePosition {
        seek(to: resumePosition)
        self.resumePosition = nil
      }
      engine.play()
      publishNowPlaying()
      persistPlayback()
      Task {
        let raw = (try? await library.lyrics(for: track)) ?? ""
        if !raw.isEmpty {
          do {
            let parsed = try await parseLyrics(raw)
            if current?.id == track.id {
              lyrics = parsed.lines
              lyricFormat = parsed.format
              rawLyrics = raw
            }
          } catch {
            if current?.id == track.id { self.error = "无法读取歌词：" + error.localizedDescription }
          }
        }
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
    if !engine.loaded {
      resumePosition = positionMs
      play(current)
      return
    }
    if !engine.playing { engine.play() } else { engine.pause() }
  }

  /// 按毫秒定位并限制在曲目时长内，同时保存恢复位置
  public func seek(to milliseconds: Double) {
    guard milliseconds.isFinite else { return }
    let value = min(max(0, milliseconds), durationMs)
    engine.seek(value)
    positionMs = value
    positionAnchor = Date()
    publishNowPlaying()
    persistPlayback()
  }

  /// 按随机或列表顺序选择下一首曲目；私人 FM 从曲池取下一首
  public func next() {
    if fmMode {
      Task { await advanceFM() }
      return
    }
    guard let id = current?.id, let index = queue.firstIndex(where: { $0.id == id }) else { return }
    if shuffle && !heartMode, let track = queue.filter({ $0.id != id }).randomElement() {
      play(track)
    } else if index + 1 < queue.count {
      play(queue[index + 1])
    } else if let first = queue.first {
      play(first)
    }
  }

  /// 已播放超过三秒时回到开头，否则切换上一首
  public func previous() {
    guard !fmMode else { return }
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
      let parsed = try await parseLyrics(text)
      if current?.id == track.id {
        lyrics = parsed.lines
        lyricFormat = parsed.format
        rawLyrics = text
      }
    } catch { self.error = "无法导入歌词：" + error.localizedDescription }
  }

  /// 本地导入复用 lyric-kit，不将 TTML 或逐字格式降级成纯文本
  private func parseLyrics(_ content: String) async throws -> (
    lines: [NativeLyricLine], format: String?
  ) {
    guard
      let response = try await service.call(["action": "parseLyrics", "content": content])
        as? [String: Any], let values = response["lines"]
    else { throw SiriFailure("歌词解析失败") }
    let lines = try JSONDecoder().decode(
      [NativeLyricLine].self, from: JSONSerialization.data(withJSONObject: values))
    return (lines, response["format"] as? String)
  }

  /// 收藏在线曲目时同时保存曲目元数据，重启后无需重新搜索；网易云曲目同步红心
  func toggleFavorite(_ track: NativeTrack) {
    let like = !isFavorite(track)
    if like {
      favoriteTracks.append(track)
    } else {
      favoriteTracks.removeAll { $0.id == track.id }
    }
    playStats.recordFavorite(add: like)
    persistPlayback()
    guard track.source == "netease", let id = track.platformTrack?["id"] else { return }
    Task {
      do {
        _ = try await service.call(["action": "like", "id": String(describing: id), "like": like])
      } catch {
        guard !(error is CancellationError) else { return }
        // 未登录时仅保留本地收藏；其余失败回滚并提示，避免与平台红心不一致
        if error.localizedDescription.contains("登录") { return }
        if like {
          favoriteTracks.removeAll { $0.id == track.id }
        } else if !favoriteTracks.contains(where: { $0.id == track.id }) {
          favoriteTracks.append(track)
        }
        persistPlayback()
        self.error = "红心同步失败：" + error.localizedDescription
      }
    }
  }

  func isFavorite(_ track: NativeTrack) -> Bool {
    favoriteTracks.contains { $0.id == track.id }
  }

  // MARK: 私人 FM 与心动模式（对应 Next core/player/fm.ts 与 useHeartMode）

  @Published private(set) var fmMode = false
  @Published private(set) var heartMode = UserDefaults.standard.bool(forKey: "native.heartMode") {
    didSet { UserDefaults.standard.set(heartMode, forKey: "native.heartMode") }
  }
  @Published private(set) var fmLoading = false
  @Published private(set) var fmOption = NativeFMOption(
    mode: UserDefaults.standard.string(forKey: "native.fm.mode") ?? "DEFAULT",
    submode: UserDefaults.standard.string(forKey: "native.fm.submode"))
  {
    didSet {
      UserDefaults.standard.set(fmOption.mode, forKey: "native.fm.mode")
      UserDefaults.standard.set(fmOption.submode, forKey: "native.fm.submode")
    }
  }
  /// 曲池首项为当前 FM 曲目
  private var fmPool: [NativeTrack] = []
  private var fmFetch: Task<Void, Never>?

  /// 开启私人 FM；传入新模式时清空曲池重新拉取。成功后播放曲池首项
  @discardableResult
  func startFM(_ option: NativeFMOption? = nil) async -> Bool {
    if let option, option != fmOption {
      fmOption = option
      fmPool = []
    }
    if fmPool.isEmpty { await fetchMoreFM() }
    guard let first = fmPool.first else { return false }
    fmMode = true
    heartMode = false
    load(first)
    return true
  }

  /// 单飞拉取：并发调用共享同一请求，按 ID 去重后追加
  private func fetchMoreFM() async {
    if let fmFetch { return await fmFetch.value }
    let option = fmOption
    fmLoading = true
    let task = Task { @MainActor in
      defer {
        fmLoading = false
        fmFetch = nil
      }
      do {
        var request: [String: Any] = ["action": "fm", "mode": option.mode]
        if let submode = option.submode { request["submode"] = submode }
        let values = try await service.call(request) as? [[String: Any]] ?? []
        guard option == fmOption else { return }
        let seen = Set(fmPool.map(\.id))
        fmPool += values.compactMap(NativeTrack.online).filter { !seen.contains($0.id) }
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    fmFetch = task
    await task.value
  }

  /// 前进一首；剩余不足时后台预取，曲池耗尽时等待新结果
  private func advanceFM() async {
    if !fmPool.isEmpty { fmPool.removeFirst() }
    if fmPool.count <= 1 { Task { await fetchMoreFM() } }
    if fmPool.isEmpty { await fetchMoreFM() }
    guard fmMode, let next = fmPool.first else { return }
    load(next)
  }

  /// FM 不喜欢：回传实际播放秒数，不等待结果直接切下一首
  func dislikeFM() {
    guard fmMode, let track = current, let id = track.platformTrack?["id"] else { return }
    let seconds = Int((positionMs / 1000).rounded())
    Task { _ = try? await service.call(["action": "fmTrash", "id": String(describing: id), "time": seconds]) }
    Task { await advanceFM() }
  }

  /// 心动模式：以指定或当前网易云曲目为种子，否则由服务从红心列表随机选取
  func startHeartMode(seed: NativeTrack? = nil) async {
    guard !heartMode else {
      error = "已处于心动模式"
      return
    }
    var request: [String: Any] = ["action": "heart"]
    let candidate = seed ?? (current?.source == "netease" ? current : nil)
    if let id = candidate?.platformTrack?["id"] { request["id"] = String(describing: id) }
    do {
      let values = try await service.call(request) as? [[String: Any]] ?? []
      let tracks = values.compactMap(NativeTrack.online)
      guard let first = tracks.first else { throw SiriFailure("心动模式开启失败，请稍后重试") }
      play(first, in: tracks, context: "心动模式")
      shuffle = false
      heartMode = true
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }

  /// 退出心动模式只改变模式，当前队列继续播放
  func exitHeartMode() { heartMode = false }

  /// 插入到当前曲目之后，对应原版“下一首播放 / 添加到队列”
  /// @param tracks - 要插入的曲目，已在队列中的会先移出再插入
  /// @returns 实际插入的数量
  @discardableResult
  func insertNext(_ tracks: [NativeTrack]) -> Int {
    let ids = Set(tracks.map(\.id)).subtracting(current.map { [$0.id] } ?? [])
    let inserting = tracks.filter { ids.contains($0.id) }
    queue.removeAll { ids.contains($0.id) }
    let index = current.flatMap { track in queue.firstIndex { $0.id == track.id } }
      .map { $0 + 1 } ?? queue.count
    queue.insert(contentsOf: inserting, at: index)
    persistPlayback()
    return inserting.count
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
      playbackContext: playbackContext,
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
        "state": current == nil ? "stopped" : isPlaying ? "playing" : "paused", "speed": speed,
        "lyricOffsetMs": lyricOffsetMs, "sendTimestamp": Date().timeIntervalSince1970 * 1000,
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
    engine.stop()
    current = nil
    lyrics = []
    lyricFormat = nil
    positionMs = 0
    durationMs = 0
    resumePosition = nil
    publishNowPlaying()
    persistPlayback()
  }

  /// 指定毫秒位置已开始的最后一行歌词
  func lyricLine(at position: Double) -> NativeLyricLine? {
    lyrics.last { $0.timeMs <= position + lyricOffsetMs }
  }

  /// 底部播放栏显示的当前歌词
  var currentLyric: NativeLyricLine? { lyricLine(at: positionMs) }

  /// 动态歌词行；与 main 一致，歌词结束 3 秒后无新行则恢复歌曲信息
  private func dynamicLyric(at position: Double) -> NativeLyricLine? {
    guard let line = lyricLine(at: position), !line.text.isEmpty else { return nil }
    if line.endMs > 0 && position + lyricOffsetMs > line.endMs + 3000 { return nil }
    return line
  }

  /// 把当前曲目与引擎状态同步给系统媒体控件；后台时界面进度不更新，因此直接读取引擎位置
  private func publishNowPlaying() {
    #if os(iOS)
      let enabled = mediaControls && current != nil
      for (command, _) in commands { command.isEnabled = enabled }
      guard enabled, let current else {
        publishedLyricID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        return
      }
      let position = engine.loaded ? engine.position : positionMs
      let line = dynamicLyrics ? dynamicLyric(at: position) : nil
      publishedLyricID = line?.id
      var info: [String: Any] = [
        MPMediaItemPropertyTitle: line?.text ?? current.title,
        MPMediaItemPropertyArtist: line == nil
          ? current.artist : "\(current.title) - \(current.artist)",
        MPMediaItemPropertyPlaybackDuration: durationMs / 1000,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: position / 1000,
        MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
      ]
      if let album = current.album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
      if let artwork = nowPlayingArtwork, artwork.id == current.id {
        info[MPMediaItemPropertyArtwork] = artwork.value
      } else {
        loadNowPlayingArtwork(for: current)
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    #endif
  }

  #if os(iOS)
    private var nowPlayingArtwork: (id: String, value: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: String?

    /// 锁屏与控制中心封面按曲目异步解码一次，切歌后旧结果不会覆盖新曲目
    private func loadNowPlayingArtwork(for track: NativeTrack) {
      guard artworkTrackID != track.id else { return }
      artworkTrackID = track.id
      artworkTask?.cancel()
      let source = track.cover?.isEmpty == false ? track.cover! : "native-default-cover"
      artworkTask = Task { [weak self] in
        guard let image = await NativeArtworkCache.shared.image(source, pixels: 600),
          !Task.isCancelled
        else { return }
        let uiImage = UIImage(cgImage: image)
        let artwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
        guard let self, self.current?.id == track.id else { return }
        self.nowPlayingArtwork = (track.id, artwork)
        self.publishNowPlaying()
      }
    }
  #endif

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
            self.engine.pause(immediate: true)
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
        Task { @MainActor [weak self] in self?.engine.pause(immediate: true) }
      }
    }
  #endif
}
