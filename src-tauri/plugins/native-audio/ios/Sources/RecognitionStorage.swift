import Foundation

enum RecognitionStorage {
  static let defaultGroup = "group.top.imsyy.splayer-next.ios.recognition"

  /// 读取实际 Mach-O 签名中的共享组，不把描述文件允许的权限误当作程序已签入的权限。
  static func groups(in data: Data) -> [String] {
    func word(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
      guard offset >= 0, offset <= data.count - 4 else { return nil }
      let bytes = (0..<4).map { UInt32(data[offset + $0]) }
      return bigEndian
        ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
        : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
    }
    guard word(0) == 0xfeedfacf, let commands = word(16), let commandBytes = word(20),
          Int(commandBytes) <= data.count - 32 else { return [] }
    var offset = 32
    let commandsEnd = 32 + Int(commandBytes)
    for _ in 0..<commands {
      guard offset <= commandsEnd - 8, let command = word(offset), let size = word(offset + 4),
            size >= 8, Int(size) <= commandsEnd - offset else { return [] }
      if command == 0x1d {
        guard size >= 16, let start = word(offset + 8), let length = word(offset + 12) else { return [] }
        let base = Int(start), end = base + Int(length)
        guard length >= 12, end <= data.count, word(base, bigEndian: true) == 0xfade0cc0,
              let count = word(base + 8, bigEndian: true), Int(count) <= (Int(length) - 12) / 8 else { return [] }
        for index in 0..<Int(count) {
          guard let relative = word(base + 16 + index * 8, bigEndian: true) else { return [] }
          let blob = base + Int(relative)
          guard blob <= end - 8, let blobSize = word(blob + 4, bigEndian: true),
                blobSize >= 8, Int(blobSize) <= end - blob else { return [] }
          if word(blob, bigEndian: true) == 0xfade7171 {
            let xml = data.subdata(in: (blob + 8)..<(blob + Int(blobSize)))
            guard let value = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else { return [] }
            return value["com.apple.security.application-groups"] as? [String] ?? []
          }
        }
        return []
      }
      offset += Int(size)
    }
    return []
  }

  static func sharedGroup(app: [String], broadcast: [String]) -> String? {
    let common = Set(app).intersection(broadcast).filter { $0.hasPrefix("group.") }
    return common.contains(defaultGroup) ? defaultGroup : common.sorted().first
  }

  /// 两个进程使用同一选择规则，且只操作自己的子目录。
  static func directory(bundle: Bundle = .main) throws -> URL {
    let appURL = bundle.bundleURL.pathExtension == "appex"
      ? bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      : bundle.bundleURL
    guard let app = Bundle(url: appURL), let plugins = app.builtInPlugInsURL,
          let extensionURL = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent == "RecognitionBroadcast.appex" }),
          let broadcast = Bundle(url: extensionURL), let appExecutable = app.executableURL,
          let broadcastExecutable = broadcast.executableURL else {
      throw failure("未找到听歌识曲广播扩展，请安装包含扩展的完整安装包")
    }
    let appGroups = groups(in: try Data(contentsOf: appExecutable, options: .mappedIfSafe))
    let broadcastGroups = groups(in: try Data(contentsOf: broadcastExecutable, options: .mappedIfSafe))
    guard let group = sharedGroup(app: appGroups, broadcast: broadcastGroups),
          let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw failure("主应用与广播扩展没有可用的共同共享组，请检查二者的重签名权限")
    }
    guard let identifier = app.bundleIdentifier, !identifier.isEmpty,
          !identifier.contains("/"), identifier != ".", identifier != ".." else {
      throw failure("无法确定识曲数据目录，请重新安装应用")
    }
    let directory = root.appendingPathComponent("SPlayerRecognition", isDirectory: true)
      .appendingPathComponent(identifier, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "SPlayerRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
