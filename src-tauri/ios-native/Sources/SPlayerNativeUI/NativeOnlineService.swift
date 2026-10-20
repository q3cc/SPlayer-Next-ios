import Foundation
import Security

struct SiriFailure: LocalizedError {
  let message: String
  /// 保留可向用户展示的错误信息
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct NativeCover: Identifiable, Codable, Equatable {
  let id: String
  let title: String
  let cover: String
  let subtitle: String?
}

/// 仅应用内平台服务读取 Keychain；第三方插件没有此对象或存储的引用
@MainActor
final class NativeOnlineService {
  private var storage: [String: String]
  private var generation = 0
  private let account = "native.platform.storage"

  /// 恢复该独立应用自己的登录态，不读取旧应用沙盒
  init() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "SPlayerNative",
      kSecAttrAccount as String: "native.platform.storage",
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let values = try? JSONDecoder().decode([String: String].self, from: data)
    {
      storage = values
    } else {
      storage = [:]
    }
  }

  /// 执行隔离的后台服务并合并该请求实际修改的会话项
  /// - Parameter request: 只由应用构造的业务请求
  /// - Returns: JSON 业务结果
  func call(_ request: [String: Any]) async throws -> Any {
    let runtime = SiriRuntime(resourceDirectory: Bundle.module.resourceURL!)
    let before = storage
    let token = generation
    let result = try await withTaskCancellationHandler(
      operation: {
        try await runtime.run(request, storage: before)
      }, onCancel: { runtime.cancel() })
    try Task.checkCancellation()
    guard token == generation else { throw CancellationError() }
    if let updated = result["storage"] as? [String: String] {
      for (key, value) in updated where before[key] != value { storage[key] = value }
      for key in before.keys where updated[key] == nil && storage[key] == before[key] {
        storage.removeValue(forKey: key)
      }
      if storage != before { try persist() }
    }
    return result["value"] ?? NSNull()
  }

  /// 清理登录态同时使在途请求失效
  func clearSession() throws {
    generation += 1
    storage = [:]
    try persist()
  }

  /// 将会话存入设备解锁后可用的 Keychain，不写入日志或普通偏好文件
  private func persist() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "SPlayerNative", kSecAttrAccount as String: account,
    ]
    let data = try JSONEncoder().encode(storage)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var value = query
      value[kSecValueData as String] = data
      value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(value as CFDictionary, nil)
      guard added == errSecSuccess else { throw SiriFailure("无法安全保存平台会话（\(added)）") }
    } else if status != errSecSuccess {
      throw SiriFailure("无法更新平台会话（\(status)）")
    }
  }
}

extension NativeTrack {
  /// 将新版共享 Track 转成原生界面模型，保留完整业务字段供解析使用
  static func online(_ value: [String: Any]) -> NativeTrack? {
    guard let title = value["title"] as? String, let source = value["source"] as? String,
      let rawID = value["id"], let data = try? JSONSerialization.data(withJSONObject: value)
    else { return nil }
    let artists = (value["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
      .joined(separator: " / ")
    let album = value["album"] as? [String: Any]
    return NativeTrack(
      id: source + ":" + String(describing: rawID), fileName: "", title: title,
      artist: artists, durationMs: (value["duration"] as? Double) ?? 0,
      cover: value["cover"] as? String, album: album?["name"] as? String,
      source: source, payload: data)
  }

  var platformTrack: [String: Any]? {
    guard let payload else { return nil }
    return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
  }
}

extension NativeTrack {
  /// 输出共享曲目格式，不包含本地文件路径和会话信息
  var sharedTrack: [String: Any] {
    platformTrack ?? [
      "id": id, "source": "local", "title": title, "artists": [["name": artist]],
      "duration": durationMs,
    ]
  }
}
