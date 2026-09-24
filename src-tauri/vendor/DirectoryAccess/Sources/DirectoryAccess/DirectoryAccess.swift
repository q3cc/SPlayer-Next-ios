import Foundation

public struct DirectoryGrant: Codable {
  public let directory: String
  public let path: String?
  public let error: String?
}

private struct Bookmark: Codable {
  let directory: String
  let data: Data
}

/** 播放器持有独立访问引用，移除曲库目录不会中断已经打开的音源。 */
public final class DirectoryLease {
  private let root: URL

  fileprivate init(_ root: URL) throws {
    guard root.startAccessingSecurityScopedResource() else {
      throw DirectoryAccess.failure("文件夹授权已失效，请重新添加文件夹")
    }
    self.root = root
  }

  deinit { root.stopAccessingSecurityScopedResource() }
}

/** 只持有已登记目录的授权；所有插件共用同一实例，后台 Siri 也可恢复书签。 */
public final class DirectoryAccess {
  public static let shared = DirectoryAccess()
  private let lock = NSRecursiveLock()
  private let defaults: UserDefaults
  private let storageKey = "splayer.directory-bookmarks.v1"
  private var bookmarks: [Bookmark] = []
  private var active: [String: URL] = [:]
  private var storageError: Error?

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    do {
      bookmarks = try defaults.data(forKey: storageKey).map {
        try JSONDecoder().decode([Bookmark].self, from: $0)
      } ?? []
    } catch {
      bookmarks = []
      storageError = error
    }
  }

  deinit {
    for url in active.values { url.stopAccessingSecurityScopedResource() }
  }

  fileprivate static func failure(_ message: String) -> NSError {
    NSError(domain: "SPlayerDirectoryAccess", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func save(_ next: [Bookmark]) throws {
    if storageError != nil { throw Self.failure("文件夹授权记录损坏，无法保存新授权") }
    let data = try JSONEncoder().encode(next)
    defaults.set(data, forKey: storageKey)
    bookmarks = next
  }

  /** 保存系统返回的目录书签，先取得权限再创建书签，不复制目录内容。 */
  public func register(_ url: URL) throws -> URL {
    lock.lock(); defer { lock.unlock() }
    guard url.startAccessingSecurityScopedResource() else {
      throw Self.failure("无法获得文件夹访问权限，请重新选择文件夹")
    }
    var retained = false
    defer { if !retained { url.stopAccessingSecurityScopedResource() } }
    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw Self.failure("请选择文件夹，而不是音频文件")
    }
    let data = try url.bookmarkData(options: .minimalBookmark,
      includingResourceValuesForKeys: nil, relativeTo: nil)
    let key = bookmarks.first(where: {
      $0.directory == url.absoluteString || active[$0.directory]?.standardizedFileURL == url.standardizedFileURL
    })?.directory ?? url.absoluteString
    let existing = bookmarks.contains(where: { $0.directory == key })
    var next = bookmarks.filter { $0.directory != key }
    guard existing || next.count < 128 else { throw Self.failure("最多可授权 128 个文件夹，请先移除不再使用的目录") }
    next.append(Bookmark(directory: key, data: data))
    try save(next)
    active.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
    active[key] = url
    retained = true
    return url
  }

  private func resolve(_ bookmark: Bookmark) throws -> URL {
    if let url = active[bookmark.directory] { return url }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark.data, options: .withoutUI,
      relativeTo: nil, bookmarkDataIsStale: &stale)
    guard url.startAccessingSecurityScopedResource() else {
      throw Self.failure("文件夹授权已失效，请重新添加文件夹")
    }
    do {
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw Self.failure("原文件夹不存在，请重新添加文件夹")
      }
      if stale {
        let data = try url.bookmarkData(options: .minimalBookmark,
          includingResourceValuesForKeys: nil, relativeTo: nil)
        try save(bookmarks.map {
          $0.directory == bookmark.directory ? Bookmark(directory: $0.directory, data: data) : $0
        })
      }
      active[bookmark.directory] = url
      return url
    } catch {
      url.stopAccessingSecurityScopedResource()
      throw error
    }
  }

  /** 单个目录失效不影响其他目录恢复，也不删除用户的曲库记录。 */
  public func restore() throws -> [DirectoryGrant] {
    lock.lock(); defer { lock.unlock() }
    if storageError != nil { throw Self.failure("文件夹授权记录损坏，请恢复应用数据后重试") }
    return bookmarks.map { bookmark in
      do {
        return DirectoryGrant(directory: bookmark.directory,
          path: try resolve(bookmark).absoluteString, error: nil)
      } catch {
        return DirectoryGrant(directory: bookmark.directory, path: nil,
          error: "文件夹不可访问，请确认目录仍存在并重新授权：\(error.localizedDescription)")
      }
    }
  }

  public func remove(_ directory: String) throws {
    lock.lock(); defer { lock.unlock() }
    let key = bookmarks.first(where: { bookmark in
      bookmark.directory == directory || active[bookmark.directory]?.absoluteString == directory
    })?.directory ?? directory
    try save(bookmarks.filter { $0.directory != key })
    active.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
  }

  /** 使用路径分段边界匹配目录，避免 Music 的授权误用于 Music-other。 */
  public static func relativePath(_ url: URL, within root: URL) -> String? {
    let path = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path
    if path == base { return "" }
    let prefix = base.hasSuffix("/") ? base : base + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
  }

  /** 恢复队列中的旧路径通过书签定位；访问引用由调用者保持到读取结束。 */
  public func source(_ url: URL) throws -> (URL, DirectoryLease?) {
    guard url.isFileURL else { return (url, nil) }
    lock.lock(); defer { lock.unlock() }
    if storageError != nil { throw Self.failure("文件夹授权记录损坏，无法打开本地歌曲") }
    let matches = bookmarks.compactMap { bookmark -> (Bookmark, String)? in
      guard let original = URL(string: bookmark.directory) else { return nil }
      let relative = Self.relativePath(url, within: original)
        ?? active[bookmark.directory].flatMap { Self.relativePath(url, within: $0) }
      guard let relative = relative else { return nil }
      return (bookmark, relative)
    }.sorted { $0.0.directory.count > $1.0.directory.count }
    guard let (bookmark, relative) = matches.first else { return (url, nil) }
    let root = try resolve(bookmark)
    return (relative.isEmpty ? root : root.appendingPathComponent(relative), try DirectoryLease(root))
  }
}
