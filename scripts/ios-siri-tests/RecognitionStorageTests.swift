import Foundation

@main
struct RecognitionStorageTests {
  static func signedImage(_ groups: [String]) throws -> Data {
    let xml = try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.application-groups": groups], format: .xml, options: 0)
    var data = Data(repeating: 0, count: 48)
    func little(_ value: UInt32, at offset: Int) {
      for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    func big(_ value: UInt32) {
      for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    little(0xfeedfacf, at: 0)
    little(1, at: 16)
    little(16, at: 20)
    little(0x1d, at: 32)
    little(16, at: 36)
    little(48, at: 40)
    little(UInt32(28 + xml.count), at: 44)
    big(0xfade0cc0); big(UInt32(28 + xml.count)); big(1)
    big(5); big(20)
    big(0xfade7171); big(UInt32(8 + xml.count))
    data.append(xml)
    return data
  }

  static func main() throws {
    let groups = ["group.resigned.z", "group.resigned.a"]
    let image = try signedImage(groups)
    precondition(RecognitionStorage.groups(in: image) == groups)
    precondition(RecognitionStorage.sharedGroup(app: groups, broadcast: Array(groups.reversed())) == "group.resigned.a")
    precondition(RecognitionStorage.sharedGroup(app: groups, broadcast: ["group.resigned.z"]) == "group.resigned.z")
    precondition(RecognitionStorage.sharedGroup(app: groups, broadcast: ["group.other"]) == nil)
    let original = groups + [RecognitionStorage.defaultGroup]
    precondition(RecognitionStorage.sharedGroup(app: original, broadcast: original) == RecognitionStorage.defaultGroup)
    for length in [0, 3, 20, 47, image.count - 1] {
      precondition(RecognitionStorage.groups(in: Data(image.prefix(length))).isEmpty)
    }
    var malformed = image
    malformed[36] = 0
    precondition(RecognitionStorage.groups(in: malformed).isEmpty)
    print("PASS: 签名权限解析、重签名共享组交集、排序一致性及截断数据")
  }
}
