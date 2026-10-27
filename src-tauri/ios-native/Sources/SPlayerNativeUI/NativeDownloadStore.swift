import Foundation

/// 下载任务状态，与 Next 的 DownloadStatus 一致
enum NativeDownloadStatus: String, Codable {
  case queued, downloading, done, failed, canceled, interrupted
  var label: String {
    switch self {
    case .queued: return "排队中"
    case .downloading: return "下载中"
    case .done: return "已完成"
    case .failed: return "失败"
    case .canceled: return "已取消"
    case .interrupted: return "已中断"
    }
  }
  var isActive: Bool { self == .queued || self == .downloading }
  var isError: Bool { self == .failed || self == .canceled || self == .interrupted }
}

struct NativeDownloadTask: Codable, Identifiable, Equatable {
  let id: String
  let track: NativeTrack
  let quality: String
  var status: NativeDownloadStatus
  var received: Int64 = 0
  var total: Int64 = 0
  var error: String?
  /// 标签写入失败但音频已保存
  var tagWarning: Bool?
  /// 加入应用曲库后的本地曲目 ID
  var localID: String?
  /// 导出到「文件」App 的相对路径
  var exportPath: String?
  let createdAt: Date
  var finishedAt: Date?
}

/// 下载配置，键名与默认值对应 Next 的 system.download.*
struct NativeDownloadOptions {
  var quality = "lossless"
  var fileTemplate = "{artist} - {title}"
  var folderScheme = "none"
  var overwrite = "rename"
  var lyricFormat = "enhanced-lrc"
  var embedCover = true
  var embedMeta = true
  var embedLyric = true
  var writeLrc = false
  var saveTtml = false
  /// 原生端额外选项：在「文件」App 中保留一份按模板命名的副本
  var exportToFiles = true

  static func current(_ defaults: UserDefaults = .standard) -> NativeDownloadOptions {
    var value = NativeDownloadOptions()
    func string(_ key: String, _ fallback: String) -> String {
      defaults.string(forKey: "native.download." + key) ?? fallback
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      defaults.object(forKey: "native.download." + key) as? Bool ?? fallback
    }
    value.quality = string("quality", value.quality)
    value.fileTemplate = string("fileTemplate", value.fileTemplate)
    value.folderScheme = string("folderScheme", value.folderScheme)
    value.overwrite = string("overwrite", value.overwrite)
    value.lyricFormat = string("lyricFormat", value.lyricFormat)
    value.embedCover = bool("embedCover", value.embedCover)
    value.embedMeta = bool("embedMeta", value.embedMeta)
    value.embedLyric = bool("embedLyric", value.embedLyric)
    value.writeLrc = bool("writeLrc", value.writeLrc)
    value.saveTtml = bool("saveTtml", value.saveTtml)
    value.exportToFiles = bool("exportToFiles", value.exportToFiles)
    return value
  }

  /// 文件名去掉路径分隔符等非法字符，过长时截断
  static func sanitize(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
    let cleaned = value.components(separatedBy: invalid).joined(separator: "_")
      .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    return String((cleaned.isEmpty ? "未知" : cleaned).prefix(120))
  }

  /// 按模板与分类规则生成相对路径（不含扩展名）
  func relativePath(for track: NativeTrack) -> String {
    let name = fileTemplate.replacingOccurrences(of: "{title}", with: track.title)
      .replacingOccurrences(of: "{artist}", with: track.artist)
    var parts: [String] = []
    if folderScheme == "artist" || folderScheme == "artist-album" {
      parts.append(Self.sanitize(track.artist))
    }
    if folderScheme == "artist-album" { parts.append(Self.sanitize(track.album ?? "未知专辑")) }
    parts.append(Self.sanitize(name))
    return parts.joined(separator: "/")
  }
}

/// 入队结果，与 Next 的 EnqueueResult 一致
enum NativeEnqueueResult: Equatable {
  case ok, queued, downloaded, unsupported
}

/// 下载管理：串行执行，任务记录持久化；完成的歌曲加入应用曲库并可选导出到「文件」App
@MainActor
final class NativeDownloadStore: ObservableObject {
  static let exportFolder = "SPlayer 下载"
  @Published private(set) var tasks: [NativeDownloadTask] = []
  private weak var player: NativePlayerStore?
  private let root: URL
  private let exports: URL
  private let service: NativeOnlineService
  private var worker: Task<Void, Never>?
  private var transfer: URLSessionDownloadTask?
  private var loaded = false
  private var lastProgress = Date.distantPast

  /// 下载中置顶，其余按入队顺序
  var activeTasks: [NativeDownloadTask] {
    tasks.filter { $0.status.isActive }.sorted {
      $0.status != $1.status ? $0.status == .downloading : $0.createdAt < $1.createdAt
    }
  }
  /// 最新结束的在前
  var historyTasks: [NativeDownloadTask] {
    tasks.filter { !$0.status.isActive }.sorted {
      ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt)
    }
  }

  init(root: URL, exports: URL, service: NativeOnlineService, player: NativePlayerStore) {
    self.root = root
    self.exports = exports
    self.service = service
    self.player = player
  }

  /// 恢复记录：上次未完成的下载标记为中断，排队任务继续
  func load() {
    guard !loaded else { return }
    loaded = true
    let url = root.appendingPathComponent("downloads.json")
    guard let data = try? Data(contentsOf: url),
      let saved = try? JSONDecoder().decode([NativeDownloadTask].self, from: data)
    else { return }
    tasks = saved.map { task in
      var task = task
      if task.status == .downloading {
        task.status = .interrupted
        task.finishedAt = Date()
      }
      return task
    }
    pump()
  }

  func isDownloaded(_ track: NativeTrack) -> Bool {
    tasks.contains { $0.track.id == track.id && $0.status == .done && localTrack($0) != nil }
  }

  /// 完成任务对应的曲库歌曲；曲库中已删除时返回 nil
  func localTrack(_ task: NativeDownloadTask) -> NativeTrack? {
    guard let id = task.localID else { return nil }
    return player?.tracks.first { $0.id == id }
  }

  @discardableResult
  func enqueue(_ track: NativeTrack) -> NativeEnqueueResult {
    load()
    guard track.source != nil, track.source != "plugin", track.platformTrack != nil else {
      return .unsupported
    }
    if tasks.contains(where: { $0.track.id == track.id && $0.status.isActive }) { return .queued }
    if isDownloaded(track) { return .downloaded }
    tasks.removeAll { $0.track.id == track.id && !$0.status.isActive }
    tasks.append(
      NativeDownloadTask(
        id: UUID().uuidString, track: track, quality: NativeDownloadOptions.current().quality,
        status: .queued, createdAt: Date()))
    persist()
    pump()
    return .ok
  }

  /// 批量入队，返回实际新增数量
  func enqueue(_ tracks: [NativeTrack]) -> Int {
    tracks.reduce(0) { $0 + (enqueue($1) == .ok ? 1 : 0) }
  }

  func cancel(_ id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status.isActive
    else { return }
    if tasks[index].status == .downloading { transfer?.cancel() }
    tasks[index].status = .canceled
    tasks[index].finishedAt = Date()
    persist()
  }

  func retry(_ id: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status.isError
    else { return }
    tasks[index].status = .queued
    tasks[index].error = nil
    tasks[index].received = 0
    tasks[index].total = 0
    tasks[index].finishedAt = nil
    persist()
    pump()
  }

  /// 只移除记录，不删除已下载的文件
  func remove(_ id: String) {
    cancel(id)
    tasks.removeAll { $0.id == id }
    persist()
  }

  /// 删除曲库副本与「文件」中的导出文件，并移除记录
  func deleteFile(_ id: String) async {
    guard let task = tasks.first(where: { $0.id == id }) else { return }
    if let local = localTrack(task) { await player?.remove(local) }
    if let path = task.exportPath {
      let base = exports.appendingPathComponent(path)
      for url in [base] + ["lrc", "ttml"].map({ base.deletingPathExtension().appendingPathExtension($0) }) {
        try? FileManager.default.removeItem(at: url)
      }
    }
    tasks.removeAll { $0.id == id }
    persist()
  }

  /// 清空已完成与出错的记录，已下载的文件保留
  func clearFinished() {
    tasks.removeAll { !$0.status.isActive }
    persist()
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try JSONEncoder().encode(tasks).write(
        to: root.appendingPathComponent("downloads.json"), options: .atomic)
    } catch { player?.error = "无法保存下载记录：" + error.localizedDescription }
  }

  private func update(_ id: String, _ change: (inout NativeDownloadTask) -> Void) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    change(&tasks[index])
  }

  /// 串行取下一项，同一时间只有一个下载连接
  private func pump() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      while let self, let next = self.tasks.first(where: { $0.status == .queued }) {
        await self.run(next)
      }
      self?.worker = nil
    }
  }

  private func run(_ task: NativeDownloadTask) async {
    guard let player else { return }
    update(task.id) { $0.status = .downloading }
    let options = NativeDownloadOptions.current()
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "download-" + task.id, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    do {
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      let source = try await player.resolveURL(task.track, quality: task.quality)
      try checkCanceled(task.id)
      let (file, response) = try await fetch(source, into: scratch, id: task.id)
      try checkCanceled(task.id)
      let head = (try? Data(contentsOf: file, options: .alwaysMapped).prefix(12)) ?? Data()
      let format =
        NativeAudioTagger.sniff(head) ?? Self.format(mime: response.mimeType)
        ?? Self.format(path: source.pathExtension) ?? "mp3"
      // 封面与歌词失败不影响音频本身
      let cover = await Self.fetchCover(task.track.cover)
      var lyrics = (ttml: "", lrc: "")
      if let payload = task.track.platformTrack,
        let response = try? await service.call([
          "action": "lyricExport", "track": payload, "format": options.lyricFormat,
        ]) as? [String: Any]
      {
        lyrics = (response["ttml"] as? String ?? "", response["lrc"] as? String ?? "")
      }
      var warning = false
      if options.embedMeta || options.embedCover || options.embedLyric {
        var tags = NativeAudioTags()
        if options.embedMeta {
          tags.title = task.track.title
          tags.artist = task.track.artist
          tags.album = task.track.album ?? ""
        }
        if options.embedCover { tags.cover = cover }
        if options.embedLyric { tags.lyrics = lyrics.lrc }
        do { try await NativeAudioTagger.write(tags, to: file, format: format) } catch {
          warning = true
        }
      }
      try checkCanceled(task.id)
      let local = try await player.registerDownload(
        file: file, format: format, track: task.track, cover: cover, lyrics: lyrics.ttml)
      var exportPath: String?
      if options.exportToFiles {
        exportPath = try? export(
          root.appendingPathComponent(local.fileName), format: format, track: task.track,
          options: options, lyrics: lyrics)
      }
      update(task.id) {
        $0.status = .done
        $0.localID = local.id
        $0.exportPath = exportPath
        $0.tagWarning = warning ? true : nil
        $0.finishedAt = Date()
        if $0.total == 0 { $0.total = $0.received }
      }
    } catch {
      update(task.id) {
        guard $0.status != .canceled else { return }
        $0.status = .failed
        $0.error = error.localizedDescription
        $0.finishedAt = Date()
      }
    }
    transfer = nil
    persist()
  }

  private func checkCanceled(_ id: String) throws {
    if tasks.first(where: { $0.id == id })?.status != .downloading { throw CancellationError() }
  }

  /// 带进度的系统下载任务；界面进度最多每 0.25 秒刷新一次
  private func fetch(_ url: URL, into folder: URL, id: String) async throws -> (URL, URLResponse) {
    let delegate = NativeDownloadDelegate(destination: folder.appendingPathComponent("audio"))
    delegate.progress = { [weak self] received, total in
      Task { @MainActor [weak self] in
        guard let self,
          Date().timeIntervalSince(self.lastProgress) >= 0.25 || received == total
        else { return }
        self.lastProgress = Date()
        self.update(id) {
          $0.received = received
          $0.total = max(0, total)
        }
      }
    }
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    return try await withCheckedThrowingContinuation { continuation in
      delegate.continuation = continuation
      let task = session.downloadTask(with: request)
      transfer = task
      task.resume()
    }
  }

  /// 按模板导出到「文件」App；同卷使用硬链接，不额外占用空间
  private func export(
    _ file: URL, format: String, track: NativeTrack, options: NativeDownloadOptions,
    lyrics: (ttml: String, lrc: String)
  ) throws -> String? {
    let manager = FileManager.default
    let relative = options.relativePath(for: track)
    var target = exports.appendingPathComponent(relative + "." + format)
    try manager.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if manager.fileExists(atPath: target.path) {
      switch options.overwrite {
      case "skip": return nil
      case "overwrite": try manager.removeItem(at: target)
      default:
        var index = 1
        repeat {
          target = exports.appendingPathComponent("\(relative) (\(index)).\(format)")
          index += 1
        } while manager.fileExists(atPath: target.path)
      }
    }
    do { try manager.linkItem(at: file, to: target) } catch {
      try manager.copyItem(at: file, to: target)
    }
    let base = target.deletingPathExtension()
    if options.writeLrc, !lyrics.lrc.isEmpty {
      try? lyrics.lrc.write(
        to: base.appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
    }
    if options.saveTtml, !lyrics.ttml.isEmpty {
      try? lyrics.ttml.write(
        to: base.appendingPathExtension("ttml"), atomically: true, encoding: .utf8)
    }
    return String(target.path.dropFirst(exports.path.count + 1))
  }

  nonisolated static func format(mime: String?) -> String? {
    switch mime?.lowercased() {
    case "audio/flac", "audio/x-flac": return "flac"
    case "audio/mpeg", "audio/mp3": return "mp3"
    case "audio/mp4", "audio/x-m4a", "audio/aac", "audio/m4a": return "m4a"
    case "audio/ogg": return "ogg"
    case "audio/wav", "audio/x-wav": return "wav"
    default: return nil
    }
  }

  nonisolated static func format(path: String) -> String? {
    let value = path.lowercased()
    return ["mp3", "flac", "m4a", "ogg", "wav"].contains(value) ? value : nil
  }

  /// 封面原图用于内嵌与曲库缩略图，限制 8MB
  nonisolated static func fetchCover(_ value: String?) async -> Data? {
    guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "")
    else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024
    else { return nil }
    return data
  }
}

/// 系统下载回调转为 async；临时文件在回调返回前移到任务目录
private final class NativeDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let destination: URL
  var progress: ((Int64, Int64) -> Void)?
  var continuation: CheckedContinuation<(URL, URLResponse), Error>?
  private var finished = false

  init(destination: URL) { self.destination = destination }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    progress?(totalBytesWritten, totalBytesExpectedToWrite)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard !finished else { return }
    finished = true
    guard let response = downloadTask.response else {
      continuation?.resume(throwing: URLError(.badServerResponse))
      return
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      continuation?.resume(throwing: SiriFailure("音源服务器返回 \(http.statusCode)"))
      return
    }
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
      continuation?.resume(returning: (destination, response))
    } catch { continuation?.resume(throwing: error) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard !finished else { return }
    finished = true
    continuation?.resume(throwing: error ?? URLError(.unknown))
  }
}
