import Foundation
import Intents
import Security
import UIKit

@MainActor
final class SiriService {
  static let shared = SiriService()
  let queue = SiriQueue()
  private var preferences: [String: Any] = [:]
  private var library: [[String: Any]] = []
  private var storage: [String: String] = [:]
  private var generation = 0
  private var runtime: SiriRuntime?
  private var lastResult = ""
  var changed: ((String) -> Void)?
  private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Siri", isDirectory: true)
  var enabled: Bool { (preferences["settings"] as? [String: Any])?["enabled"] as? Bool == true }
  var askBeforePlaying: Bool { (preferences["settings"] as? [String: Any])?["askBeforePlaying"] as? Bool ?? true }

  private init() {
    if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
       let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      preferences = saved["preferences"] as? [String: Any] ?? [:]
      library = saved["library"] as? [[String: Any]] ?? []
      queue.restore(saved["playback"] as? [String: Any] ?? [:])
    }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("playback.json")),
       let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { queue.restore(value) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "top.imsyy.splayer.siri", kSecAttrAccount as String: "sessions",
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
      storage = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
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
    if !enabled { SecItemDelete(query as CFDictionary); storage = [:]; return }
    let data = try JSONSerialization.data(withJSONObject: storage)
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
    switch INPreferences.siriAuthorizationStatus() {
    case .authorized: authorization = "authorized"
    case .denied: authorization = "denied"
    case .restricted: authorization = "restricted"
    default: authorization = "notDetermined"
    }
    return ["authorization": authorization, "enabled": enabled, "lastResult": lastResult]
  }

  func command(_ request: [String: Any]) async throws -> [String: Any] {
    switch request["action"] as? String {
    case "status": return status()
    case "authorize":
      await withCheckedContinuation { continuation in
        INPreferences.requestSiriAuthorization { _ in continuation.resume() }
      }
      return status()
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
      return status()
    case "configure":
      let nextPreferences = request["preferences"] as? [String: Any] ?? [:]
      let nextStorage = request["storage"] as? [String: String] ?? [:]
      if !NSDictionary(dictionary: preferences).isEqual(to: nextPreferences) || storage != nextStorage {
        generation += 1; runtime?.cancel()
      }
      preferences = nextPreferences
      storage = nextStorage
      library = request["library"] as? [[String: Any]] ?? []
      try saveCredentials(); try persist()
      return status()
    case "snapshot":
      if ["playing", "paused"].contains(NativeAudioPlugin.shared.snapshot()["state"] as? String ?? "") { checkpoint() }
      return queue.json
    case "interrupt":
      generation += 1; runtime?.cancel()
      return queue.json
    case "syncQueue":
      let accepted = queue.replace(request["snapshot"] as? [String: Any] ?? [:])
      if accepted {
        generation += 1; runtime?.cancel(); try persistPlayback()
      }
      return ["accepted": accepted, "snapshot": queue.json]
    default: return try await execute(request)
    }
  }

  private func checkEnabled() throws {
    guard enabled else { throw SiriFailure("请先在 SPlayer 设置的 Siri 页面开启语音控制") }
    guard INPreferences.siriAuthorizationStatus() == .authorized else { throw SiriFailure("请允许 SPlayer 使用 Siri") }
  }

  private func request(_ action: String, query: String = "", artist: String = "", track: [String: Any]? = nil) async throws -> [String: Any] {
    let settings = preferences["settings"] as? [String: Any] ?? [:]
    let configured = settings["source"] as? String ?? "current"
    var value: [String: Any] = ["action": action, "query": query, "artist": artist,
      "source": configured == "current" ? preferences["source"] as? String ?? "netease" : configured,
      "scope": settings["searchScope"] as? String ?? "localFirst", "library": library,
      "quality": preferences["quality"] as? String ?? "hq", "allowTrial": preferences["allowTrial"] as? Bool ?? false]
    if let track = track { value["track"] = track }
    let token = generation
    runtime?.cancel()
    let worker = SiriRuntime()
    runtime = worker
    let response = try await worker.run(value, storage: storage)
    guard token == generation else { throw SiriFailure("已被新的播放操作取消") }
    if let updated = response["storage"] as? [String: String] { storage = updated; try saveCredentials() }
    runtime = nil
    return response["value"] as? [String: Any] ?? [:]
  }

  func search(query: String, artist: String = "") async throws -> [[String: Any]] {
    try checkEnabled()
    return try await request("search", query: query, artist: artist)["tracks"] as? [[String: Any]] ?? []
  }

  func play(_ track: [String: Any], replacing: [[String: Any]]? = nil) async throws {
    generation += 1
    let token = generation
    let source = try await request("resolve", track: track)
    guard token == generation, let url = source["url"] as? String else { throw SiriFailure("歌曲地址不可用") }
    let player = NativeAudioPlugin.shared
    _ = try await withCheckedThrowingContinuation { continuation in
      player.startSource(url, autoPlay: true) { result in continuation.resume(with: result) }
    }
    guard token == generation else { throw SiriFailure("已被新的播放操作取消") }
    player.setSiriMetadata(track)
    queue.select(track, replacing: replacing)
    queue.playing = true
    try persistPlayback()
    changed?(try encode(queue.json))
    lastResult = source["isTrial"] as? Bool == true ? "正在播放试听片段" : "已开始播放"
  }

  func advance(_ direction: Int, ended: Bool = false) async throws {
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
        if matches.count > 1 && askBeforePlaying && request["confirmed"] as? Bool != true { return ["choices": matches] }
        try await play(first, replacing: matches)
      case "playTrack":
        guard let track = request["track"] as? [String: Any] else { throw SiriFailure("请选择歌曲") }
        try await play(track)
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
      default: throw SiriFailure("不支持的 Siri 操作")
      }
      return ["message": lastResult]
    } catch {
      lastResult = "执行失败，请检查授权、网络和歌曲权限"
      throw error
    }
  }

  func checkpoint() {
    let value = NativeAudioPlugin.shared.snapshot()
    queue.position = value["position"] as? Double ?? queue.position
    queue.playing = value["state"] as? String == "playing"
    try? persistPlayback()
  }

  private func encode(_ value: [String: Any]) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
  }
}
