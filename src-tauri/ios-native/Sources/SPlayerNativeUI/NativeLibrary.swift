import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct NativeTrack: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let fileName: String
  public let title: String
  public let artist: String
  public let durationMs: Double
  public var cover: String?
  public var album: String?
  public var source: String?
  public var payload: Data?

  /// 新版稳定身份由平台与曲目 ID 组成，本地旧 UUID 编码继续可读
  public init(
    id: String, fileName: String, title: String, artist: String, durationMs: Double,
    cover: String? = nil, album: String? = nil, source: String? = nil, payload: Data? = nil
  ) {
    self.id = id
    self.fileName = fileName
    self.title = title
    self.artist = artist
    self.durationMs = durationMs
    self.cover = cover
    self.album = album
    self.source = source
    self.payload = payload
  }

  /// 保留已有本地曲库与调用方的 UUID 入口
  public init(id: UUID, fileName: String, title: String, artist: String, durationMs: Double) {
    self.init(
      id: id.uuidString, fileName: fileName, title: title, artist: artist, durationMs: durationMs)
  }
}

public struct NativeLyricWord: Decodable, Equatable {
  let text: String
  let startMs: Double
  let endMs: Double
}

public struct NativeLyricLine: Identifiable, Equatable, Decodable {
  public let id: Int
  public let timeMs: Double
  public let text: String
  var endMs: Double = 0
  var translation: String = ""
  var words: [NativeLyricWord] = []

  /// 解析 LRC 多时间戳，统一为按时间排序的毫秒行
  public static func parse(_ text: String) -> [NativeLyricLine] {
    let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]"#)
    var values: [(Double, String)] = []
    for raw in text.components(separatedBy: .newlines) {
      let source = raw as NSString
      let matches = pattern.matches(in: raw, range: NSRange(location: 0, length: source.length))
      guard let last = matches.last else { continue }
      let content = source.substring(from: NSMaxRange(last.range)).trimmingCharacters(
        in: .whitespaces)
      for match in matches {
        let minutes = Double(source.substring(with: match.range(at: 1))) ?? 0
        let seconds = Double(source.substring(with: match.range(at: 2))) ?? 0
        let fraction =
          match.range(at: 3).location == NSNotFound
          ? "" : source.substring(with: match.range(at: 3))
        values.append(((minutes * 60 + seconds + (Double("0." + fraction) ?? 0)) * 1000, content))
      }
    }
    return values.sorted { $0.0 < $1.0 }.enumerated().map {
      NativeLyricLine(id: $0.offset, timeMs: $0.element.0, text: $0.element.1)
    }
  }
}

/// 文件复制与索引持久化不占用主线程，索引仅保存沙盒内相对文件名。
public actor NativeLibrary {
  public let root: URL
  private let manager = FileManager.default

  /// 注入曲库存储目录，支持独立测试沙盒
  public init(root: URL) { self.root = root }

  /// 将用户曲库放在独立应用的 Documents 目录
  public static func defaultRoot() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NativeMusic", isDirectory: true)
  }

  /// 读取曲库并拒绝越出沙盒的索引文件名
  public func load() throws -> [NativeTrack] {
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let index = root.appendingPathComponent("library.json")
    guard manager.fileExists(atPath: index.path) else { return [] }
    let values = try JSONDecoder().decode([NativeTrack].self, from: Data(contentsOf: index))
    guard
      values.allSatisfy({
        URL(fileURLWithPath: $0.fileName).lastPathComponent == $0.fileName
          && !$0.fileName.hasPrefix(".")
      })
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return values
  }

  /// 复制用户选定文件并读取音频元数据，失败时撤销副本
  public func importFile(_ source: URL) async throws -> NativeTrack {
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let fileName = id.uuidString + "." + source.pathExtension.lowercased()
    let destination = root.appendingPathComponent(fileName)
    try manager.copyItem(at: source, to: destination)
    do {
      let asset = AVURLAsset(url: destination)
      guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadUnsupportedScheme) }
      let metadata = try await asset.load(.commonMetadata)
      var title = source.deletingPathExtension().lastPathComponent
      var artist = "未知歌手"
      var album: String?
      var cover: String?
      for item in metadata {
        if item.commonKey == .commonKeyAlbumName { album = try? await item.load(.stringValue) }
        if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.dataValue),
          data.count <= 8 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 300,
              kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        {
          let url = root.appendingPathComponent(id.uuidString + ".jpg")
          if let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
          {
            CGImageDestinationAddImage(
              destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
            )
            if CGImageDestinationFinalize(destination) {
              cover = "native-cover:" + id.uuidString + ".jpg"
            }
          }
        }
        if item.commonKey == .commonKeyTitle, let value = try? await item.load(.stringValue),
          !value.isEmpty
        {
          title = value
        }
        if item.commonKey == .commonKeyArtist, let value = try? await item.load(.stringValue),
          !value.isEmpty
        {
          artist = value
        }
      }
      let seconds = try await asset.load(.duration).seconds
      let track = NativeTrack(
        id: id.uuidString, fileName: fileName, title: title, artist: artist,
        durationMs: seconds.isFinite ? max(0, seconds * 1000) : 0, cover: cover, album: album)
      var tracks = try load()
      tracks.append(track)
      try save(tracks)
      return track
    } catch {
      try? manager.removeItem(at: destination)
      try? manager.removeItem(at: root.appendingPathComponent(id.uuidString + ".jpg"))
      throw error
    }
  }

  /// 删除应用内记录和副本，保留用户原始文件
  public func remove(_ track: NativeTrack) throws {
    let tracks = try load().filter { $0.id != track.id }
    let source = root.appendingPathComponent(track.fileName)
    let staged = root.appendingPathComponent(track.id + ".deleted")
    let present = manager.fileExists(atPath: source.path)
    if present { try manager.moveItem(at: source, to: staged) }
    do { try save(tracks) } catch {
      if present { try? manager.moveItem(at: staged, to: source) }
      throw error
    }
    if present { try? manager.removeItem(at: staged) }
    try? manager.removeItem(at: root.appendingPathComponent(track.lyricFileName))
    try? manager.removeItem(at: root.appendingPathComponent(track.id + ".jpg"))
  }

  /// 读取当前曲目对应的本地歌词文件
  public func lyrics(for track: NativeTrack) throws -> String {
    let url = root.appendingPathComponent(track.lyricFileName)
    return manager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
  }

  /// 读取用户授权的歌词文件并保存到当前曲目
  public func importLyrics(_ source: URL, for track: NativeTrack) throws -> String {
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
    let text = try String(contentsOf: source, encoding: .utf8)
    try text.write(
      to: root.appendingPathComponent(track.lyricFileName), atomically: true, encoding: .utf8)
    return text
  }

  /// 原子写入索引，避免中断时留下半个 JSON 文件
  private func save(_ tracks: [NativeTrack]) throws {
    try JSONEncoder().encode(tracks).write(
      to: root.appendingPathComponent("library.json"), options: .atomic)
  }
}

struct NativePlaybackState: Codable {
  var queue: [NativeTrack] = []
  var currentID: String?
  var positionMs: Double = 0
  var favorites: [NativeTrack] = []
  var history: [NativeTrack] = []
}

extension NativeLibrary {
  /// 恢复队列、收藏和进度；从不在恢复时自动播放
  func loadPlayback() throws -> NativePlaybackState {
    let url = root.appendingPathComponent("playback.json")
    guard manager.fileExists(atPath: url.path) else { return NativePlaybackState() }
    return try JSONDecoder().decode(NativePlaybackState.self, from: Data(contentsOf: url))
  }

  /// 原子保存有限长度的播放记录，不存放音源临时地址或认证数据
  func savePlayback(_ state: NativePlaybackState) throws {
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(
      to: root.appendingPathComponent("playback.json"), options: .atomic)
  }
}

extension NativeTrack {
  /// 在线标识可能包含斜线，只用 URL 安全编码作为歌词文件名；旧本地 UUID 文件保持可读
  var lyricFileName: String {
    if UUID(uuidString: id) != nil { return id + ".lrc" }
    return Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-") + ".lrc"
  }
}

struct NativePlaylist: Codable, Identifiable, Equatable {
  let id: String
  var name: String
  var tracks: [NativeTrack]
}

extension NativeLibrary {
  /// 歌单独立于旧曲库索引保存，升级不改变原有数据格式
  func loadPlaylists() throws -> [NativePlaylist] {
    let url = root.appendingPathComponent("playlists.json")
    guard manager.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([NativePlaylist].self, from: Data(contentsOf: url))
  }
  /// 原子保存原生本地歌单
  func savePlaylists(_ values: [NativePlaylist]) throws {
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(values).write(
      to: root.appendingPathComponent("playlists.json"), options: .atomic)
  }
}

extension NativeLibrary {
  /// 推荐歌单收藏仅保存轻量封面信息
  func loadBookmarks() throws -> [NativeCover] {
    let url = root.appendingPathComponent("bookmarks.json")
    guard manager.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([NativeCover].self, from: Data(contentsOf: url))
  }
  /// 原子保存推荐歌单收藏，不改动平台账号收藏
  func saveBookmarks(_ values: [NativeCover]) throws {
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(values).write(
      to: root.appendingPathComponent("bookmarks.json"), options: .atomic)
  }
}
