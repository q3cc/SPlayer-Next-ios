import Foundation
import Intents
import Security
import SiriAuthorization
import UIKit

@MainActor
final class SiriService {
  static let shared = SiriService()
  let queue = SiriQueue()
  let selection = SiriSelection()
  private var preferences: [String: Any] = [:]
  private var library: [[String: Any]] = []
  private var storage: [String: String] = [:]
  private var frontendStorage: [String: String] = [:]
  private var generation = 0
  private var runtime: SiriRuntime?
  private var awaitingPlayback: Int?
  private var lastResult = ""
  private var pendingSearch: [String: Any] = [:]
  private var catalogGeneration = 0
  private var catalogTask: Task<Void, Never>?
  private var catalogRuntime: SiriRuntime?
  private var advancing = false
  var managesCollection: Bool { queue.collection != nil }
  var needsConfirmation: Bool { pendingSearch["needsConfirmation"] as? Bool ?? true }
  var changed: ((String) -> Void)?
  private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Siri", isDirectory: true)
  var enabled: Bool { (preferences["settings"] as? [String: Any])?["enabled"] as? Bool == true }
  var askBeforePlaying: Bool { (preferences["settings"] as? [String: Any])?["askBeforePlaying"] as? Bool ?? true }

  private init() {
    if let data = try? Data(contentsOf: directory.appendingPathComponent("selection.json")),
       let tracks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      selection.replace(tracks)
    }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("selection.json")),
       let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      pendingSearch = result
      selection.replace(result["tracks"] as? [[String: Any]] ?? [])
    }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
       let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      preferences = saved["preferences"] as? [String: Any] ?? [:]
      library = saved["library"] as? [[String: Any]] ?? []
      queue.restore(saved["playback"] as? [String: Any] ?? [:])
    }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("playback.json")),
       let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { queue.restore(value) }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("progress.json")),
       let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       value["revision"] as? Int == queue.revision,
       value["currentId"] as? String == queue.currentKey {
      queue.position = value["position"] as? Double ?? queue.position
    }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "top.imsyy.splayer.siri", kSecAttrAccount as String: "sessions",
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
      if let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        storage = saved["storage"] as? [String: String] ?? saved as? [String: String] ?? [:]
        frontendStorage = saved["frontend"] as? [String: String] ?? storage
      }
    }
  }

  func persist() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let saved: [String: Any] = ["preferences": preferences, "library": library]
    try JSONSerialization.data(withJSONObject: saved).write(to: directory.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try persistPlayback()
  }

  private func persistPlayback() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: queue.json).write(to: directory.appendingPathComponent("playback.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private func saveCredentials() throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "top.imsyy.splayer.siri", kSecAttrAccount as String: "sessions"]
    if !enabled { SecItemDelete(query as CFDictionary); storage = [:]; frontendStorage = [:]; return }
    let data = try JSONSerialization.data(withJSONObject: ["storage": storage, "frontend": frontendStorage])
    let attributes: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if result == errSecItemNotFound {
      let status = SecItemAdd(query.merging(attributes) { _, next in next } as CFDictionary, nil)
      if status != errSecSuccess { throw SiriFailure("无法安全保存 Siri 登录状态") }
    } else if result != errSecSuccess { throw SiriFailure("无法更新 Siri 登录状态") }
  }

  func status() -> [String: Any] {
    let authorization: String
    switch splayerSiriAuthorizationStatus() {
    case INSiriAuthorizationStatus.authorized.rawValue: authorization = "authorized"
    case INSiriAuthorizationStatus.denied.rawValue: authorization = "denied"
    case INSiriAuthorizationStatus.restricted.rawValue: authorization = "restricted"
    case -1: authorization = "missingEntitlement"
    default: authorization = "notDetermined"
    }
    return ["authorization": authorization, "enabled": enabled, "lastResult": lastResult]
  }

  func command(_ request: [String: Any]) async throws -> [String: Any] {
    switch request["action"] as? String {
    case "status": return status()
    case "authorize":
      await withCheckedContinuation { continuation in
        splayerRequestSiriAuthorization { _ in continuation.resume() }
      }
      return status()
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
      return status()
    case "configure":
      let nextPreferences = request["preferences"] as? [String: Any] ?? [:]
      let nextStorage = request["storage"] as? [String: String] ?? [:]
      if !NSDictionary(dictionary: preferences).isEqual(to: nextPreferences) || frontendStorage != nextStorage {
        generation += 1; runtime?.cancel()
      }
      preferences = nextPreferences
      if !enabled { cancelCatalog(); queue.collection = nil }
      if queue.collection != nil {
        queue.repeatMode = preferences["repeatMode"] as? String
        queue.shuffleMode = preferences["shuffleMode"] as? String
      }
      // 网页没有重新登录或退出时，保留后台接口更新过的凭据。
      for (key, value) in nextStorage where frontendStorage[key] != value { storage[key] = value }
      for key in frontendStorage.keys where nextStorage[key] == nil { storage.removeValue(forKey: key) }
      frontendStorage = nextStorage
      library = request["library"] as? [[String: Any]] ?? []
      try saveCredentials(); try persist()
      return status()
    case "snapshot":
      if ["playing", "paused"].contains(NativeAudioPlugin.shared.snapshot()["state"] as? String ?? "") { checkpoint(); scheduleCatalog() }
      return queue.json.merging(["pending": runtime != nil || awaitingPlayback != nil]) { _, next in next }
    case "interrupt":
      generation += 1; runtime?.cancel()
      cancelCatalog(); queue.collection = nil
      try persistPlayback()
      return queue.json
    case "syncQueue":
      let previousKeys = queue.tracks.map(SiriQueue.key)
      let accepted = queue.replace(request["snapshot"] as? [String: Any] ?? [:])
      if accepted {
        if queue.tracks.map(SiriQueue.key) != previousKeys { cancelCatalog(); queue.collection = nil }
        generation += 1; runtime?.cancel()
        checkpoint()
        try persistPlayback()
      }
      return ["accepted": accepted, "snapshot": queue.json]
    default: return try await execute(request)
    }
  }

  private func checkEnabled() throws {
    guard enabled else { throw SiriFailure("请先在 SPlayer 设置的 Siri 页面开启语音控制") }
    let authorization = status()["authorization"] as? String
    guard authorization != "missingEntitlement" else { throw SiriFailure("当前签名缺少 Siri 能力，请使用支持 Siri 的证书和描述文件重新签名") }
    guard authorization == "authorized" else { throw SiriFailure("请允许 SPlayer 使用 Siri") }
  }

  private func requestValue(_ action: String, query: String = "", artist: String = "", track: [String: Any]? = nil) -> [String: Any] {
    let settings = preferences["settings"] as? [String: Any] ?? [:]
    let configured = settings["source"] as? String ?? "current"
    var value: [String: Any] = ["action": action, "query": query, "artist": artist,
      "source": configured == "current" ? preferences["source"] as? String ?? "netease" : configured,
      "scope": settings["searchScope"] as? String ?? "localFirst", "library": library,
      "vipSources": preferences["vipSources"] as? [String] ?? [],
      "quality": preferences["quality"] as? String ?? "hq", "allowTrial": preferences["allowTrial"] as? Bool ?? false]
    if let track = track { value["track"] = track }
    return value
  }

  private func request(_ action: String, query: String = "", artist: String = "", track: [String: Any]? = nil, collection: [String: Any]? = nil) async throws -> [String: Any] {
    var value = requestValue(action, query: query, artist: artist, track: track)
    if let collection = collection { value["collection"] = collection }
    let token = generation
    runtime?.cancel()
    let worker = SiriRuntime()
    runtime = worker
    defer { if runtime === worker { runtime = nil } }
    let response = try await worker.run(value, storage: storage)
    guard token == generation else { throw SiriFailure("已被新的播放操作取消") }
    if let updated = response["storage"] as? [String: String] { storage = updated; try saveCredentials() }
    runtime = nil
    return response["value"] as? [String: Any] ?? [:]
  }

  func search(query: String, artist: String = "") async throws -> [[String: Any]] {
    try checkEnabled()
    generation += 1; runtime?.cancel()
    cancelCatalog(); queue.collection = nil
    var result = try await request("search", query: query, artist: artist)
    while (result["tracks"] as? [[String: Any]] ?? []).isEmpty,
          result["pageFailed"] as? Bool != true,
          let collection = result["collection"] as? [String: Any],
          let cursors = collection["cursors"] as? [[String: Any]],
          cursors.contains(where: { $0["done"] as? Bool != true }) {
      result = try await request("artistPage", collection: collection)
    }
    let tracks = result["tracks"] as? [[String: Any]] ?? []
    pendingSearch = result
    selection.replace(tracks)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result).write(
      to: directory.appendingPathComponent("selection.json"),
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return tracks
  }

  private func cancelCatalog() {
    catalogGeneration += 1
    queue.repeatMode = nil; queue.shuffleMode = nil
    catalogTask?.cancel(); catalogTask = nil
    catalogRuntime?.cancel(); catalogRuntime = nil
  }

  private func playSearch(_ first: [String: Any]) async throws {
    let result = pendingSearch
    cancelCatalog()
    queue.collection = result["collection"] as? [String: Any]
    let matches = result["tracks"] as? [[String: Any]] ?? [first]
    if managesCollection {
      queue.repeatMode = "list"; queue.shuffleMode = "off"
      preferences["repeatMode"] = "list"; preferences["shuffleMode"] = "off"
      try await playAvailable(matches, replacing: matches)
    } else { try await play(first, replacing: matches) }
    pendingSearch = [:]
    try JSONSerialization.data(withJSONObject: pendingSearch).write(to: directory.appendingPathComponent("selection.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    scheduleCatalog()
  }

  private func playAvailable(_ tracks: [[String: Any]], replacing: [[String: Any]]? = nil) async throws {
    for track in tracks.prefix(5) {
      let token = generation
      do { try await play(track, replacing: replacing); return }
      catch { if generation != token + 1 { throw error } }
    }
    _ = try? NativeAudioPlugin.shared.performControl("stop")
    queue.playing = false
    try persistPlayback()
    throw SiriFailure("连续歌曲无法播放，请检查网络、会员权限或试听设置")
  }

  /// 分页使用独立运行时，不能取消正在进行的歌曲地址解析。
  private func scheduleCatalog() {
    guard enabled, catalogTask == nil, queue.collection != nil else { return }
    let token = catalogGeneration
    catalogTask = Task { @MainActor in
      var more = false
      defer {
        if token == self.catalogGeneration {
          self.catalogTask = nil; self.catalogRuntime = nil
          if more { self.scheduleCatalog() }
        }
      }
      if !Task.isCancelled, token == self.catalogGeneration,
            let collection = self.queue.collection,
            let cursors = collection["cursors"] as? [[String: Any]],
            cursors.contains(where: { $0["done"] as? Bool != true }) {
        var value = self.requestValue("artistPage")
        value["collection"] = collection
        let worker = SiriRuntime()
        self.catalogRuntime = worker
        let originalStorage = self.storage
        do {
          let response = try await worker.run(value, storage: originalStorage)
          guard token == self.catalogGeneration, !Task.isCancelled,
                let result = response["value"] as? [String: Any] else { return }
          if let updated = response["storage"] as? [String: String] {
            for (key, value) in updated where value != originalStorage[key] && self.storage[key] == originalStorage[key] { self.storage[key] = value }
            try self.saveCredentials()
          }
          self.queue.collection = result["collection"] as? [String: Any]
          self.queue.append(result["tracks"] as? [[String: Any]] ?? [])
          try self.persistPlayback()
          self.changed?(try self.encode(self.queue.json))
          if result["pageFailed"] as? Bool == true { return }
          more = true
        } catch { self.lastResult = "曲库补充暂时失败，已加载歌曲仍可播放"; return }
      }
    }
  }

  func play(_ track: [String: Any], replacing: [[String: Any]]? = nil) async throws {
    generation += 1
    let token = generation
    awaitingPlayback = token
    defer { if awaitingPlayback == token { awaitingPlayback = nil } }
    let source = try await request("resolve", track: track)
    let resolvedTrack = source["track"] as? [String: Any] ?? track
    guard token == generation, let url = source["url"] as? String else { throw SiriFailure("歌曲地址不可用") }
    let player = NativeAudioPlugin.shared
    _ = try await withCheckedThrowingContinuation { continuation in
      player.startSource(url, autoPlay: true, trackId: SiriQueue.key(resolvedTrack)) { result in continuation.resume(with: result) }
    }
    guard token == generation else { throw SiriFailure("已被新的播放操作取消") }
    player.setSiriMetadata(resolvedTrack, enabled: preferences["mediaEnabled"] as? Bool ?? true)
    let resolvedQueue = (replacing ?? queue.tracks).map { SiriQueue.key($0) == SiriQueue.key(track) ? resolvedTrack : $0 }
    queue.select(resolvedTrack, replacing: resolvedQueue)
    queue.playing = true
    try persistPlayback()
    changed?(try encode(queue.json))
    lastResult = source["isTrial"] as? Bool == true ? "正在播放试听片段" : "已开始播放"
  }

  func advance(_ direction: Int, ended: Bool = false) async throws {
    if advancing { return }
    advancing = true
    defer { advancing = false }
    if managesCollection {
      let catalogToken = catalogGeneration
      if ended, (queue.repeatMode ?? "list") == "one", let current = queue.current {
        try await play(current); return
      }
      let index = queue.tracks.firstIndex { SiriQueue.key($0) == queue.currentKey } ?? 0
      var candidates = direction > 0 ? Array(queue.tracks.dropFirst(index + 1)) : Array(queue.tracks.prefix(index).reversed())
      if candidates.isEmpty && direction > 0 {
        scheduleCatalog()
        while let page = catalogTask {
          await page.value
          guard catalogToken == catalogGeneration else { throw SiriFailure("已切换播放队列") }
          candidates = Array(queue.tracks.dropFirst(index + 1))
          if !candidates.isEmpty { break }
        }
      }
      if candidates.isEmpty { candidates = direction > 0 ? queue.tracks : Array(queue.tracks.reversed()) }
      if queue.shuffleMode == "on" { candidates.shuffle() }
      try await playAvailable(candidates)
      scheduleCatalog()
      return
    }
    if ended, preferences["repeatMode"] as? String == "one", let current = queue.current {
      try await play(current)
    } else if direction > 0, preferences["shuffleMode"] as? String == "on",
              let next = queue.tracks.filter({ SiriQueue.key($0) != queue.currentKey }).randomElement() {
      try await play(next)
    } else { try await play(queue.neighbor(direction)) }
  }

  func execute(_ request: [String: Any]) async throws -> [String: Any] {
    try checkEnabled()
    do {
      switch request["action"] as? String {
      case "search": return ["tracks": try await search(query: request["query"] as? String ?? "", artist: request["artist"] as? String ?? "")]
      case "playQuery":
        let matches = try await search(query: request["query"] as? String ?? "", artist: request["artist"] as? String ?? "")
        guard let first = matches.first else { throw SiriFailure("没有找到匹配的歌曲") }
        if needsConfirmation && askBeforePlaying && request["confirmed"] as? Bool != true { return ["choices": Array(matches.prefix(3))] }
        try await playSearch(first)
      case "playTrack":
        guard let track = request["track"] as? [String: Any] else { throw SiriFailure("请选择歌曲") }
        if pendingSearch["collection"] != nil && selection.tracks.contains(where: { SiriQueue.key($0) == SiriQueue.key(track) }) {
          try await playSearch(track)
        } else {
          cancelCatalog(); queue.collection = nil
          try await play(track)
        }
      case "next": try await advance(1)
      case "previous": try await advance(-1)
      case "pause":
        generation += 1; runtime?.cancel()
        _ = try NativeAudioPlugin.shared.performControl("pause")
        checkpoint()
        lastResult = "已暂停"
      case "resume":
        let state = NativeAudioPlugin.shared.snapshot()["state"] as? String
        if state == "paused" || state == "playing" { _ = try NativeAudioPlugin.shared.performControl("play") }
        else if let current = queue.current {
          let position = queue.position
          try await play(current)
          if position > 0 { _ = try? NativeAudioPlugin.shared.performControl("seek", position: position) }
        } else { throw SiriFailure("没有可恢复的歌曲，请先选择音乐") }
        lastResult = "已继续播放"
        scheduleCatalog()
      default: throw SiriFailure("不支持的 Siri 操作")
      }
      return ["message": lastResult]
    } catch {
      lastResult = "执行失败，请检查授权、网络和歌曲权限"
      throw error
    }
  }

  func checkpoint() {
    let player = NativeAudioPlugin.shared
    let value = player.snapshot()
    guard let state = value["state"] as? String, ["playing", "paused"].contains(state),
          let position = value["position"] as? Double,
          queue.checkpoint(trackId: player.currentTrackId, position: position, playing: state == "playing") else { return }
    // 高频存档只写进度；整份队列仅在切歌或队列变更时写入。
    let progress: [String: Any] = ["revision": queue.revision,
      "currentId": queue.currentKey as Any? ?? NSNull(), "position": queue.position]
    try? JSONSerialization.data(withJSONObject: progress).write(to: directory.appendingPathComponent("progress.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private func encode(_ value: [String: Any]) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
  }
}
