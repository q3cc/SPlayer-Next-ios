import Combine
import Foundation

struct NativePluginRecord: Codable, Identifiable {
  let id: String
  var name: String
  var version: String
  var description: String?
  var grant: [String]
  var permissions: [String: Bool]
  var enabled: Bool
  var source: String
  var storage: Data = Data("{}".utf8)
}

/// 插件的生命周期、联网和持久化由原生宿主管理，运行时无法访问平台 Keychain
@MainActor
final class NativePluginStore: ObservableObject {
  @Published private(set) var records: [NativePluginRecord] = []
  @Published private(set) var states: [String: String] = [:]
  @Published private(set) var sources: [String: [String: [String: Any]]] = [:]
  @Published var error: String?
  @Published var importing = false
  @Published var notification: String?
  weak var player: NativePlayerStore?
  private var machines: [String: NativePluginVM] = [:]
  private var pending: [String: CheckedContinuation<Any, Error>] = [:]
  private var tasks: [String: [String: Task<Void, Never>]] = [:]
  private var imports: [UUID: NativePluginVM] = [:]
  private let directory: URL
  private var loaded = false

  /// 建立插件专用存储目录并弱引用播放器
  init(root: URL = NativeLibrary.defaultRoot(), player: NativePlayerStore? = nil) {
    directory = root.appendingPathComponent("plugins", isDirectory: true)
    self.player = player
  }

  /// 启动时恢复用户明确启用的脚本，最多 16 个插件
  func load() {
    guard !loaded else { return }
    loaded = true
    do {
      let url = directory.appendingPathComponent("plugins.json")
      if FileManager.default.fileExists(atPath: url.path) {
        records = try JSONDecoder().decode([NativePluginRecord].self, from: Data(contentsOf: url))
        guard records.count <= 16 else { throw SiriFailure("已安装插件超过上限") }
        for record in records where record.enabled { start(record) }
      }
    } catch { self.error = error.localizedDescription }
  }

  /// HTTPS 下载后先解析与校验，再保存为禁用状态由用户确认启用
  func importURL(_ text: String) async {
    guard !importing else { return }
    importing = true
    defer { importing = false }
    do {
      guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
        url.scheme == "https"
      else { throw SiriFailure("请使用 HTTPS 插件链接") }
      let result = try await Self.request(url: url, options: [:], limit: 9_000_000)
      guard let status = result["status"] as? Int, (200..<300).contains(status),
        let source = result["body"] as? String
      else { throw SiriFailure("下载插件失败") }
      try await importSource(source)
    } catch { self.error = error.localizedDescription }
  }

  /// 文件导入和链接导入共用同一解析器，安装不执行第三方源码
  func importSource(_ source: String) async throws {
    guard source.utf8.count <= 9_000_000 else { throw SiriFailure("插件源码超过大小限制") }
    let id = UUID()
    let machine = NativePluginVM()
    imports[id] = machine
    defer { imports.removeValue(forKey: id)?.stop() }
    let parsed: Any = try await withCheckedThrowingContinuation { continuation in
      let key = "import:" + id.uuidString
      pending[key] = continuation
      machine.message = { [weak self, weak machine] message in
        Task { @MainActor in
          if message["kind"] as? String == "hostReady" { machine?.inspect(source) }
          if message["kind"] as? String == "manifest" {
            self?.finish(key, result: .success(message["data"] ?? NSNull()))
          }
        }
      }
      machine.failure = { [weak self] reason in
        Task { @MainActor in self?.finish(key, result: .failure(SiriFailure(reason))) }
      }
      machine.start()
      timeout(key, milliseconds: 10_000)
    }
    guard let value = parsed as? [String: Any], let manifest = value["manifest"] as? [String: Any],
      let source = value["source"] as? String, source.utf8.count <= 9_000_000,
      let pluginID = manifest["id"] as? String, let name = manifest["name"] as? String,
      let version = manifest["version"] as? String, let grant = manifest["grant"] as? [String]
    else { throw SiriFailure("插件信息无效") }
    guard records.count < 16 || records.contains(where: { $0.id == pluginID }) else {
      throw SiriFailure("最多安装 16 个插件")
    }
    guard !records.contains(where: { $0.id == pluginID }) else {
      throw SiriFailure("该插件已安装，请先移除旧版本再导入")
    }
    records.append(
      NativePluginRecord(
        id: pluginID, name: name, version: version, description: manifest["description"] as? String,
        grant: grant, permissions: Dictionary(uniqueKeysWithValues: grant.map { ($0, true) }),
        enabled: false, source: source))
    try save()
    states[pluginID] = "已禁用"
  }

  /// 禁用立即中断计算与联网，并拒绝所有等待中的调用
  func setEnabled(_ id: String, _ enabled: Bool) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].enabled = enabled
    stop(id)
    if enabled { start(records[index]) } else { states[id] = "已禁用" }
    persist()
  }

  /// 权限收回后重启隔离线程，使旧请求和旧响应同时失效
  func setPermission(_ id: String, _ permission: String, _ allowed: Bool) {
    guard let index = records.firstIndex(where: { $0.id == id }),
      records[index].grant.contains(permission)
    else { return }
    records[index].permissions[permission] = allowed
    stop(id)
    if records[index].enabled { start(records[index]) }
    persist()
  }

  /// 停止插件并移除安装记录，不影响其他插件
  func remove(_ id: String) {
    stop(id)
    records.removeAll { $0.id == id }
    states.removeValue(forKey: id)
    sources.removeValue(forKey: id)
    persist()
  }

  /// 按已启用源的声明解析地址，不偷偷使用其他插件结果
  func resolve(_ track: NativeTrack) async throws -> String? {
    guard let platform = track.source, let payload = track.platformTrack else { return nil }
    if platform == "plugin", let metadata = payload["plugin"] as? [String: Any],
      let id = metadata["pluginId"] as? String,
      let source = metadata["source"] as? String, let info = metadata["musicInfo"] as? [String: Any]
    {
      let qualities = sources[id]?[source]?["qualities"] as? [String] ?? []
      let quality = qualities.contains("hq") ? "hq" : qualities.first ?? "hq"
      let value = try await call(
        id, action: "musicUrl", params: ["source": source, "quality": quality, "musicInfo": info])
      guard let text = (value as? [String: Any])?["url"] as? String ?? value as? String,
        let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "")
      else { throw SiriFailure("插件没有返回有效音源") }
      return text
    }
    let code =
      platform == "netease"
      ? "wy" : platform == "qqmusic" ? "tx" : platform == "kugou" ? "kg" : platform
    for record in records where record.enabled && allowed(record.id, "network") {
      guard let capabilities = sources[record.id]?[code],
        (capabilities["actions"] as? [String] ?? []).contains("musicUrl")
      else { continue }
      var info = payload["lxMusicInfo"] as? [String: Any] ?? [:]
      info["songmid"] = payload["id"]
      info["name"] = track.title
      info["singer"] = track.artist
      info["duration"] = track.durationMs / 1000
      if let album = payload["album"] { info["albumInfo"] = album }
      let qualities = capabilities["qualities"] as? [String] ?? []
      let quality = qualities.contains("hq") ? "hq" : qualities.first ?? "hq"
      let value = try await call(
        record.id, action: "musicUrl",
        params: ["source": code, "quality": quality, "musicInfo": info])
      let raw = (value as? [String: Any])?["url"] as? String ?? value as? String
      if let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
        return raw
      }
    }
    return nil
  }

  /// 独立搜索复用上游候选校验与分页规则，来源 ID 随曲目保存
  func search(_ id: String, source: String, keyword: String, page: Int = 1) async throws -> [String:
    Any]
  {
    guard let player, sources[id]?[source]?["actions"] as? [String] != nil,
      (sources[id]?[source]?["actions"] as? [String] ?? []).contains("musicSearch")
    else { throw SiriFailure("此插件来源不支持搜索") }
    let input: [String: Any] = [
      "pluginId": id, "source": source, "keyword": keyword, "page": page, "limit": 20,
    ]
    let result = try await call(id, action: "musicSearch", params: input)
    guard states[id] == "可用" else { throw SiriFailure("插件搜索已取消") }
    return try await player.service.call([
      "action": "pluginHost", "method": "normalizeSearch", "args": [input, result],
    ]) as? [String: Any] ?? [:]
  }

  /// 每插件最多 64 个待处理调用，超时会终止解释器
  func call(_ id: String, action: String, params: [String: Any]) async throws -> Any {
    guard let machine = machines[id], states[id] == "可用" else { throw SiriFailure("插件尚未就绪") }
    guard pending.keys.filter({ $0.hasPrefix(id + ":") }).count < 64 else {
      throw SiriFailure("插件调用过多")
    }
    let requestID = UUID().uuidString
    let key = id + ":" + requestID
    return try await withCheckedThrowingContinuation { continuation in
      pending[key] = continuation
      machine.send([
        "kind": "call", "pluginId": id, "requestId": requestID, "action": action, "params": params,
      ])
      timeout(key, milliseconds: 20_000, plugin: id)
    }
  }

  /// 创建独立插件实例，旧实例回调不得修改新状态
  private func start(_ record: NativePluginRecord) {
    let machine = NativePluginVM()
    machines[record.id] = machine
    states[record.id] = "正在加载"
    machine.message = { [weak self, weak machine] message in
      Task { @MainActor in
        guard let self, let machine, self.machines[record.id] === machine else { return }
        self.receive(record.id, machine: machine, message: message)
      }
    }
    machine.failure = { [weak self, weak machine] reason in
      Task { @MainActor in
        guard let self, let machine, self.machines[record.id] === machine else { return }
        self.states[record.id] = reason
        self.stop(record.id)
      }
    }
    machine.start()
    Task { [weak self, weak machine] in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      guard let self, let machine, self.machines[record.id] === machine,
        self.states[record.id] == "正在加载"
      else { return }
      self.states[record.id] = "插件加载超时"
      self.stop(record.id)
    }
  }

  /// 分发解释器消息，并将宿主调用留在原生权限边界
  private func receive(_ id: String, machine: NativePluginVM, message: [String: Any]) {
    switch message["kind"] as? String {
    case "hostReady":
      guard let record = records.first(where: { $0.id == id }) else { return }
      machine.send([
        "kind": "loadPlugin", "pluginId": id, "apiLevel": 5, "locale": "zh-CN",
        "appVersion": "2.1.0", "userSettings": [:], "source": record.source,
        "scriptInfo": [
          "name": record.name, "version": record.version, "description": record.description ?? "",
          "author": "", "homepage": "",
        ],
      ])
    case "ready", "sourcesUpdate":
      sources[id] = message["sources"] as? [String: [String: Any]] ?? [:]
      states[id] = "可用"
    case "fatal":
      states[id] = (message["error"] as? [String: Any])?["message"] as? String ?? "插件运行失败"
      stop(id)
    case "result":
      guard let requestID = message["requestId"] as? String else { return }
      let result: Result<Any, Error> =
        message["ok"] as? Bool == true
        ? .success(message["data"] ?? NSNull())
        : .failure(
          SiriFailure((message["error"] as? [String: Any])?["message"] as? String ?? "插件调用失败"))
      finish(id + ":" + requestID, result: result)
    case "hostCall":
      guard let callID = message["callId"] as? String, let method = message["method"] as? String,
        let args = message["args"] as? [Any]
      else { return }
      if (tasks[id]?.count ?? 0) >= 16 {
        machine.send([
          "kind": "hostResult", "pluginId": id, "callId": callID, "ok": false,
          "error": ["message": "插件请求过多"],
        ])
        return
      }
      tasks[id, default: [:]][callID] = Task { [weak self, weak machine] in
        guard let self, let machine else { return }
        defer { self.tasks[id]?.removeValue(forKey: callID) }
        do {
          let result = try await self.host(id, method: method, args: args)
          try Task.checkCancellation()
          guard self.machines[id] === machine else { return }
          machine.send([
            "kind": "hostResult", "pluginId": id, "callId": callID, "ok": true, "data": result,
          ])
        } catch {
          guard self.machines[id] === machine else { return }
          machine.send([
            "kind": "hostResult", "pluginId": id, "callId": callID, "ok": false,
            "error": ["message": error.localizedDescription],
          ])
        }
      }
    default: break
    }
  }

  /// 先检查插件授权，再执行有界宿主接口
  func host(_ id: String, method: String, args: [Any]) async throws -> Any {
    if method == "request" {
      guard allowed(id, "network") else { throw SiriFailure("联网权限已关闭") }
      guard let text = args.first as? String, let url = URL(string: text),
        ["http", "https"].contains(url.scheme ?? "")
      else { throw SiriFailure("链接无效") }
      let value = try await Self.request(
        url: url, options: args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:])
      guard allowed(id, "network") else { throw SiriFailure("联网权限已关闭") }
      return value
    }
    guard let index = records.firstIndex(where: { $0.id == id }) else { throw SiriFailure("插件已移除") }
    if method.hasPrefix("storage.") {
      var values =
        (try? JSONSerialization.jsonObject(with: records[index].storage)) as? [String: Any] ?? [:]
      let key = args.first as? String ?? ""
      switch method {
      case "storage.get": return values[key] ?? NSNull()
      case "storage.keys": return Array(values.keys)
      case "storage.remove": values.removeValue(forKey: key)
      case "storage.set":
        guard args.count == 2, key.utf8.count <= 1024, values.count < 128 || values[key] != nil
        else { throw SiriFailure("插件存储超出上限") }
        values[key] = args[1]
      default: throw SiriFailure("不支持的存储操作")
      }
      let encoded = try JSONSerialization.data(withJSONObject: values)
      guard encoded.count <= 16 * 1024 * 1024 else { throw SiriFailure("插件存储超出上限") }
      records[index].storage = encoded
      try save()
      return NSNull()
    }
    let grant =
      method == "music.searchOnline"
      ? "network"
      : method == "music.searchLibrary"
        ? "library"
        : method == "api.call"
          ? "api" : method == "notify" ? "ui" : method.hasPrefix("player.") ? "control" : ""
    guard !grant.isEmpty, allowed(id, grant) else { throw SiriFailure("此接口的权限已关闭") }
    guard let player else { throw SiriFailure("播放器尚未就绪") }
    let direct = [
      "player.play", "player.pause", "player.stop", "player.next", "player.prev",
      "player.getPosition", "player.getStatus", "player.getNowPlaying",
    ]
    if direct.contains(method) { return try player.pluginControl(method, args: []) }
    let value = try await player.service.call([
      "action": "pluginHost", "method": method, "args": args,
    ])
    guard allowed(id, grant) else { throw SiriFailure("此接口的权限已关闭") }
    if method == "api.call" || method == "music.searchOnline" { return value }
    guard let checked = value as? [Any] else { throw SiriFailure("宿主参数校验失败") }
    if method == "music.searchLibrary" {
      let query = checked[0] as! String
      let limit = checked[1] as! Int
      let found = player.tracks.filter {
        ($0.title + " " + $0.artist + " " + ($0.album ?? "")).localizedCaseInsensitiveContains(
          query)
      }
      return ["total": found.count, "tracks": Array(found.prefix(limit)).map(\.sharedTrack)]
    }
    if method == "notify" {
      notification =
        (records.first(where: { $0.id == id })?.name ?? "插件") + "：" + (checked[0] as! String)
      return NSNull()
    }
    return try player.pluginControl(method, args: checked)
  }

  /// 结合声明权限、用户授权和启用状态判断能力
  func allowed(_ id: String, _ grant: String) -> Bool {
    guard let record = records.first(where: { $0.id == id }), record.enabled else { return false }
    return record.grant.contains(grant) && record.permissions[grant] != false
  }
  /// 停止解释器、网络任务和该插件全部待处理请求
  private func stop(_ id: String) {
    machines.removeValue(forKey: id)?.stop()
    tasks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
    for key in Array(pending.keys) where key.hasPrefix(id + ":") {
      finish(key, result: .failure(SiriFailure("插件已停止")))
    }
    sources.removeValue(forKey: id)
  }
  /// 一次性完成并移除对应的异步请求
  private func finish(_ key: String, result: Result<Any, Error>) {
    pending.removeValue(forKey: key)?.resume(with: result)
  }
  /// 超时完成请求，必要时停止失去响应的插件
  private func timeout(_ key: String, milliseconds: UInt64, plugin: String? = nil) {
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
      guard let self, self.pending[key] != nil else { return }
      self.finish(key, result: .failure(SiriFailure("插件请求超时")))
      if let plugin {
        self.stop(plugin)
        self.states[plugin] = "插件请求超时"
      }
    }
  }
  /// 保存插件状态并向界面报告存储失败
  private func persist() { do { try save() } catch { self.error = error.localizedDescription } }
  /// 原子保存插件清单、启用状态与各自的存储
  private func save() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(records).write(
      to: directory.appendingPathComponent("plugins.json"), options: .atomic)
  }

  /// 无 Cookie 存储的临时网络会话，流式读取并在超限时立即取消
  static func request(url: URL, options: [String: Any], limit: Int = 32 * 1024 * 1024) async throws
    -> [String: Any]
  {
    let method = (options["method"] as? String ?? "GET").uppercased()
    guard ["GET", "POST"].contains(method) else { throw SiriFailure("不支持此请求方法") }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(
      url: url, timeoutInterval: min(60, max(1, (options["timeout"] as? Double ?? 15000) / 1000)))
    request.httpMethod = method
    request.allHTTPHeaderFields = options["headers"] as? [String: String]
    if let body = options["body"] as? String {
      request.httpBody = Data(body.utf8)
    } else if let bytes = (options["body"] as? [String: Any])?["__nativeBytes"] as? [UInt8] {
      request.httpBody = Data(bytes)
    }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw SiriFailure("插件响应无效") }
    var data = Data()
    for try await byte in bytes {
      if data.count >= limit { throw SiriFailure("插件响应超过大小限制") }
      data.append(byte)
    }
    let headers = Dictionary(
      response.allHeaderFields.map {
        (String(describing: $0.key).lowercased(), String(describing: $0.value))
      }, uniquingKeysWith: { _, value in value })
    let body: Any
    if options["responseType"] as? String == "arraybuffer" {
      body = ["__nativeBytes": Array(data)]
    } else if options["responseType"] as? String == "json",
      let json = try? JSONSerialization.jsonObject(with: data)
    {
      body = json
    } else {
      body = String(data: data, encoding: .utf8) ?? ""
    }
    return ["status": response.statusCode, "headers": headers, "body": body]
  }
}
