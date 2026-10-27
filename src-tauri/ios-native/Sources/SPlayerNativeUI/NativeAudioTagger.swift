import AVFoundation
import Foundation

/// 下载文件写入的标签内容；空字段不写入
struct NativeAudioTags: Equatable {
  var title = ""
  var artist = ""
  var album = ""
  var cover: Data?
  var lyrics = ""
}

/// 下载完成后写入音频标签：MP3 使用 ID3v2.3，FLAC 使用 Vorbis Comment 与 PICTURE 块，M4A 交给系统重新封装
enum NativeAudioTagger {
  enum Failure: Error { case unsupported, malformed }

  /// 根据文件头判断实际容器格式，平台返回的扩展名不一定可靠
  static func sniff(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    guard bytes.count >= 4 else { return nil }
    if bytes.starts(with: Array("fLaC".utf8)) { return "flac" }
    if bytes.starts(with: Array("ID3".utf8)) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) {
      return "mp3"
    }
    if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "m4a" }
    if bytes.starts(with: Array("OggS".utf8)) { return "ogg" }
    if bytes.starts(with: Array("RIFF".utf8)) { return "wav" }
    return nil
  }

  /// 原地改写文件；失败时保留原始音频，由调用方标记“标签写入失败”
  static func write(_ tags: NativeAudioTags, to url: URL, format: String) async throws {
    switch format {
    case "mp3":
      let data = try Data(contentsOf: url)
      try id3(data, tags: tags).write(to: url, options: .atomic)
    case "flac":
      let data = try Data(contentsOf: url)
      try flac(data, tags: tags).write(to: url, options: .atomic)
    case "m4a":
      try await mp4(url, tags: tags)
    default:
      throw Failure.unsupported
    }
  }

  // MARK: - ID3v2.3

  /// 去掉已有 ID3v2 标签后写入新标签
  static func id3(_ data: Data, tags: NativeAudioTags) throws -> Data {
    var audio = data
    let bytes = [UInt8](data.prefix(10))
    if bytes.count == 10, bytes.starts(with: Array("ID3".utf8)) {
      let size = bytes[6...9].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
      let footer = bytes[5] & 0x10 != 0 ? 10 : 0
      guard 10 + size + footer <= data.count else { throw Failure.malformed }
      audio = data.subdata(in: (data.startIndex + 10 + size + footer)..<data.endIndex)
    }
    var frames = Data()
    for (id, value) in [("TIT2", tags.title), ("TPE1", tags.artist), ("TALB", tags.album)]
    where !value.isEmpty {
      frames.append(frame(id, [0x01] + utf16(value)))
    }
    if let cover = tags.cover {
      let mime = cover.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
      var body = Data([0x00]) + Data(mime.utf8) + Data([0x00, 0x03, 0x00])
      body.append(cover)
      frames.append(frame("APIC", body))
    }
    if !tags.lyrics.isEmpty {
      var body = Data([0x01]) + Data("XXX".utf8)
      body.append(utf16("") + Data([0x00, 0x00]))
      body.append(utf16(tags.lyrics))
      frames.append(frame("USLT", body))
    }
    var header = Data("ID3".utf8) + Data([0x03, 0x00, 0x00])
    header.append(synchsafe(frames.count))
    return header + frames + audio
  }

  private static func frame(_ id: String, _ body: Data) -> Data {
    var frame = Data(id.utf8)
    frame.append(bigEndian(UInt32(body.count)))
    frame.append(contentsOf: [0x00, 0x00])
    frame.append(body)
    return frame
  }

  /// UTF-16LE 带 BOM，ID3v2.3 的通用 Unicode 编码
  private static func utf16(_ text: String) -> Data {
    var data = Data([0xFF, 0xFE])
    for unit in text.utf16 { data.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
    return data
  }

  private static func synchsafe(_ value: Int) -> Data {
    Data([
      UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F),
      UInt8(value & 0x7F),
    ])
  }

  // MARK: - FLAC

  /// 保留 STREAMINFO 与其他元数据块，替换注释和封面块
  static func flac(_ data: Data, tags: NativeAudioTags) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.starts(with: Array("fLaC".utf8)) else { throw Failure.malformed }
    var offset = 4
    var blocks: [(type: UInt8, body: [UInt8])] = []
    var last = false
    var oldComments: [String] = []
    while !last {
      guard offset + 4 <= bytes.count else { throw Failure.malformed }
      last = bytes[offset] & 0x80 != 0
      let type = bytes[offset] & 0x7F
      let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
      guard offset + 4 + length <= bytes.count else { throw Failure.malformed }
      let body = Array(bytes[(offset + 4)..<(offset + 4 + length)])
      if type == 4 { oldComments = vorbisComments(body) }
      // 原有注释与封面被替换，填充块丢弃
      if type != 4 && type != 6 && type != 1 { blocks.append((type, body)) }
      offset += 4 + length
    }
    guard blocks.first?.type == 0 else { throw Failure.malformed }
    // 保留与新标签不冲突的原有字段
    let replaced: Set<String> = ["TITLE", "ARTIST", "ALBUM", "LYRICS", "UNSYNCEDLYRICS"]
    var comments = oldComments.filter {
      !replaced.contains($0.split(separator: "=", maxSplits: 1).first?.uppercased() ?? "")
    }
    for (key, value) in [
      ("TITLE", tags.title), ("ARTIST", tags.artist), ("ALBUM", tags.album),
      ("LYRICS", tags.lyrics),
    ] where !value.isEmpty {
      comments.append(key + "=" + value)
    }
    var comment = littleEndian(UInt32(Data("SPlayer Next".utf8).count)) + Data("SPlayer Next".utf8)
    comment.append(littleEndian(UInt32(comments.count)))
    for item in comments {
      comment.append(littleEndian(UInt32(Data(item.utf8).count)))
      comment.append(Data(item.utf8))
    }
    blocks.insert((4, [UInt8](comment)), at: 1)
    if let cover = tags.cover {
      let mime = cover.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
      var picture = bigEndian(3) + bigEndian(UInt32(mime.utf8.count)) + Data(mime.utf8)
      picture.append(bigEndian(0))
      picture.append(bigEndian(0) + bigEndian(0) + bigEndian(0) + bigEndian(0))
      picture.append(bigEndian(UInt32(cover.count)))
      picture.append(cover)
      blocks.insert((6, [UInt8](picture)), at: 2)
    }
    var output = Data("fLaC".utf8)
    for (index, block) in blocks.enumerated() {
      guard block.body.count < 1 << 24 else { throw Failure.malformed }
      let flag: UInt8 = index == blocks.count - 1 ? 0x80 : 0
      output.append(flag | block.type)
      output.append(contentsOf: [
        UInt8(block.body.count >> 16 & 0xFF), UInt8(block.body.count >> 8 & 0xFF),
        UInt8(block.body.count & 0xFF),
      ])
      output.append(contentsOf: block.body)
    }
    output.append(data.subdata(in: (data.startIndex + offset)..<data.endIndex))
    return output
  }

  /// 读取已有 Vorbis 注释，格式异常时视为空
  static func vorbisComments(_ body: [UInt8]) -> [String] {
    func read(_ at: Int) -> Int? {
      guard at + 4 <= body.count else { return nil }
      return Int(body[at]) | Int(body[at + 1]) << 8 | Int(body[at + 2]) << 16
        | Int(body[at + 3]) << 24
    }
    guard let vendor = read(0), let count = read(4 + vendor) else { return [] }
    var offset = 8 + vendor
    var items: [String] = []
    for _ in 0..<min(count, 10_000) {
      guard let length = read(offset), offset + 4 + length <= body.count else { break }
      items.append(String(decoding: body[(offset + 4)..<(offset + 4 + length)], as: UTF8.self))
      offset += 4 + length
    }
    return items
  }

  private static func bigEndian(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
  }

  private static func littleEndian(_ value: UInt32) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
  }

  // MARK: - MP4

  /// 直通封装只改写元数据，不重新编码音频
  private static func mp4(_ url: URL, tags: NativeAudioTags) async throws {
    let asset = AVURLAsset(url: url)
    guard
      let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
    else { throw Failure.unsupported }
    var items: [AVMetadataItem] = []
    func add(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?) {
      guard let value else { return }
      let item = AVMutableMetadataItem()
      item.identifier = identifier
      item.value = value
      items.append(item)
    }
    if !tags.title.isEmpty { add(.commonIdentifierTitle, tags.title as NSString) }
    if !tags.artist.isEmpty { add(.commonIdentifierArtist, tags.artist as NSString) }
    if !tags.album.isEmpty { add(.commonIdentifierAlbumName, tags.album as NSString) }
    if let cover = tags.cover { add(.commonIdentifierArtwork, cover as NSData) }
    if !tags.lyrics.isEmpty { add(.iTunesMetadataLyrics, tags.lyrics as NSString) }
    let output = url.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".m4a")
    session.outputURL = output
    session.outputFileType = .m4a
    session.metadata = items
    await session.export()
    guard session.status == .completed else {
      try? FileManager.default.removeItem(at: output)
      throw session.error ?? Failure.unsupported
    }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
  }
}
