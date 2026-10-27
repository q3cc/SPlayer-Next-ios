import Foundation

/// 仓库贡献者
struct NativeContributor: Identifiable, Equatable {
  let login: String
  let htmlUrl: String
  let avatar: String
  var id: String { login.lowercased() }
}

/// 可用的新版本
struct NativeRelease: Equatable {
  let version: String
  let notes: String
  let page: URL
}

/// GitHub 仓库接口，对应 main 的 `apis/github.ts` 与 `mobile/update.ts` 的版本比较
enum NativeGitHub {
  /// iOS 版本仓库
  static let iosRepo = "q3cc/SPlayer-Next-ios"
  /// 原版仓库
  static let originalRepo = "SPlayer-Dev/SPlayer-Next"
  static let repoURL = URL(string: "https://github.com/" + iosRepo)!

  private static func request(_ url: URL) async throws -> Any {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("SPlayer-Next-ios", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as? HTTPURLResponse
    guard let http, http.statusCode == 200 else {
      let status = http?.statusCode ?? 0
      if status == 429 || (status == 403 && http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0") {
        throw SiriFailure("GitHub 请求次数已用完，请稍后重试")
      }
      throw SiriFailure("GitHub HTTP \(status)")
    }
    return try JSONSerialization.jsonObject(with: data)
  }

  /// 获取仓库贡献者；传入比较基准时只统计相对原版新增的提交，避免把继承历史计入 iOS 版本
  /// @param repo - 仓库 owner/name
  /// @param compareBase - 比较基准，例如 `SPlayer-Dev:main`
  /// @returns 去重后的贡献者，机器人账号不计入
  static func contributors(_ repo: String, compareBase: String? = nil) async throws
    -> [NativeContributor]
  {
    var result: [NativeContributor] = []
    var seen = Set<String>()
    var total = 0
    for page in 1... {
      let path =
        compareBase.map { "compare/\($0)...main?per_page=100&page=\(page)" }
        ?? "contributors?per_page=100&anon=true&page=\(page)"
      let data = try await request(URL(string: "https://api.github.com/repos/\(repo)/\(path)")!)
      let items =
        (compareBase == nil ? data : (data as? [String: Any])?["commits"]) as? [[String: Any]]
      guard let items else { throw SiriFailure("GitHub 贡献者数据无效") }
      for item in items {
        guard let author = (compareBase == nil ? item : item["author"] as? [String: Any]) else {
          continue
        }
        let login = author["login"] as? String
        if author["type"] as? String == "Bot" || login == "type-bot" { continue }
        if compareBase != nil && login == nil { continue }
        let name = login ?? author["name"] as? String ?? "anonymous"
        guard seen.insert(name.lowercased()).inserted else { continue }
        result.append(
          NativeContributor(
            login: name,
            htmlUrl: author["html_url"] as? String ?? (login.map { "https://github.com/" + $0 } ?? ""),
            avatar: author["avatar_url"] as? String ?? ""))
      }
      total += items.count
      let expected = (data as? [String: Any])?["total_commits"] as? Int ?? 0
      if items.isEmpty || (compareBase != nil ? total >= expected : items.count < 100) { break }
    }
    return result
  }

  /// 识别 iOS 标签及正式、alpha、beta 版本，预发布排在正式版之前
  /// @param text - 标签或版本号，例如 `ios-v2.1.0-beta.2`
  /// @returns 可逐位比较的版本数组
  static func versionParts(_ text: String) -> [Int]? {
    let pattern = #"^(?:ios-)?v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta)(?:\.(\d+))?)?(?:\+[\w.-]+)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    let group = { (index: Int) -> String? in
      Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
    let stage = group(4) == "alpha" ? -2 : group(4) == "beta" ? -1 : 0
    return [Int(group(1)!)!, Int(group(2)!)!, Int(group(3)!)!, stage, Int(group(5) ?? "0") ?? 0]
  }

  /// 在正式版通道中选出比当前更新且带 IPA 的版本
  /// @param releases - GitHub Releases 列表
  /// @param current - 当前版本号
  /// @returns 最新版本，没有更新时为 nil
  static func newest(in releases: [[String: Any]], current: String) -> NativeRelease? {
    guard let now = versionParts(current) else { return nil }
    let candidates = releases.compactMap { release -> ([Int], [String: Any])? in
      guard release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
        let tag = release["tag_name"] as? String, let version = versionParts(tag), version[3] == 0,
        (release["assets"] as? [[String: Any]] ?? []).contains(where: {
          ($0["name"] as? String ?? "").hasSuffix(".ipa") && $0["state"] as? String == "uploaded"
            && ($0["size"] as? Int ?? 0) > 0
        })
      else { return nil }
      return (version, release)
    }.sorted { $1.0.lexicographicallyPrecedes($0.0) }
    guard let (version, release) = candidates.first, now.lexicographicallyPrecedes(version),
      let tag = release["tag_name"] as? String
    else { return nil }
    let page = repoURL.appendingPathComponent("releases/tag").appendingPathComponent(tag)
    return NativeRelease(
      version: tag.replacingOccurrences(
        of: #"^(?:ios-)?v?"#, with: "", options: .regularExpression),
      notes: (release["body"] as? String ?? "").replacingOccurrences(
        of: #"<!-- splayer-action:.*? -->"#, with: "", options: .regularExpression
      ).trimmingCharacters(in: .whitespacesAndNewlines),
      page: page)
  }

  /// 检查正式版更新
  /// @param current - 当前版本号
  /// @returns 新版本，已是最新时为 nil
  static func checkUpdate(current: String) async throws -> NativeRelease? {
    let data = try await request(
      URL(string: "https://api.github.com/repos/\(iosRepo)/releases?per_page=100")!)
    guard let releases = data as? [[String: Any]] else { throw SiriFailure("无法识别更新版本") }
    return newest(in: releases, current: current)
  }
}
