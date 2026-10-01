import Foundation
import Security
import Tauri

private struct LastfmCredentialRequest: Decodable {
  let action: String
  let value: String?
  let namespace: String?
}

extension NativeAudioPlugin {
  /// 保留系统错误码，便于区分重签名权限缺失和设备锁定，不输出凭证内容。
  private func credentialError(_ operation: String, _ status: OSStatus) -> String {
    if status == errSecMissingEntitlement {
      return "\(operation)失败：应用签名缺少钥匙串权限（\(status)），请检查重签名配置"
    }
    if status == errSecInteractionNotAllowed {
      return "\(operation)失败：钥匙串暂不可用（\(status)），请解锁设备后重试"
    }
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知系统错误"
    return "\(operation)失败（\(status)）：\(detail)"
  }
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
      guard status == errSecSuccess else { invoke.reject(credentialError("读取安全凭证", status)); return }
      guard let data = item as? Data,
            let value = String(data: data, encoding: .utf8) else { invoke.reject("安全凭证格式无效"); return }
      invoke.resolve(["value": value])
    case "set":
      guard let data = request.value?.data(using: .utf8) else { invoke.reject("缺少 Last.fm 凭证"); return }
      let attributes: [String: Any] = [kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
      var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      }
      guard status == errSecSuccess else { invoke.reject(credentialError("保存安全凭证", status)); return }
      invoke.resolve()
    case "clear":
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { invoke.reject(credentialError("删除安全凭证", status)); return }
      invoke.resolve()
    default: invoke.reject("未知凭证操作")
    }
  }
}
