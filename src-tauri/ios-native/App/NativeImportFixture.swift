#if DEBUG
import Foundation

/// 调试构建中提供真实的音频文件，UI 测试仍通过系统文件选择器完成导入。
enum NativeImportFixture {
    static func prepare() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var data = Data()
        func word(_ value: UInt32, bytes: Int) {
            for offset in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        data.append(Data("RIFF".utf8)); word(160036, bytes: 4)
        data.append(Data("WAVEfmt ".utf8)); word(16, bytes: 4)
        word(1, bytes: 2); word(1, bytes: 2); word(8000, bytes: 4)
        word(16000, bytes: 4); word(2, bytes: 2); word(16, bytes: 2)
        data.append(Data("data".utf8)); word(160000, bytes: 4)
        data.append(Data(repeating: 0, count: 160000))
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try? data.write(to: documents.appendingPathComponent("SPlayerImportTest.wav"))
    }
}
#endif
