import Foundation
import Security
import Tauri

private struct LastfmCredentialRequest: Decodable {
  let action: String
  let value: String?
  let namespace: String?
}

extension NativeAudioPlugin {
  /// Last.fm 会话仅保存在本机钥匙串，不进入设置导出和 WebView 存储。
  @objc func lastfmCredentials(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(LastfmCredentialRequest.self)
    guard request.namespace == nil || request.namespace == "aiModels" else { invoke.reject("未知凭证类型"); return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: request.namespace == "aiModels" ? "splayer.ai-models" : "splayer.lastfm",
      kSecAttrAccount as String: "session"
    ]
    switch request.action {
    case "get":
      var read = query
      read[kSecReturnData as String] = true
      read[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(read as CFDictionary, &item)
      if status == errSecItemNotFound { invoke.resolve(["value": NSNull()]); return }
      guard status == errSecSuccess, let data = item as? Data,
            let value = String(data: data, encoding: .utf8) else { invoke.reject("无法读取 Last.fm 凭证"); return }
      invoke.resolve(["value": value])
    case "set":
      guard let data = request.value?.data(using: .utf8) else { invoke.reject("缺少 Last.fm 凭证"); return }
      let attributes: [String: Any] = [kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
      var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      }
      guard status == errSecSuccess else { invoke.reject("无法保存 Last.fm 凭证"); return }
      invoke.resolve()
    case "clear":
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { invoke.reject("无法删除 Last.fm 凭证"); return }
      invoke.resolve()
    default: invoke.reject("未知凭证操作")
    }
  }
}
