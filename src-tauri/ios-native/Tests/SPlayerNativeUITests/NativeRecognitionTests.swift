import XCTest

@testable import SPlayerNativeUI

@MainActor
final class NativeRecognitionTests: XCTestCase {
  /// 8 kHz 单声道样本在打包的 AFP 运行时中生成非空且稳定的指纹
  func testFingerprintRuntimeProducesStableOutput() async throws {
    let pcm = Self.melody(seconds: 8)
    let first = try await NativeFingerprint.compute(pcm)
    let second = try await NativeFingerprint.compute(pcm)
    XCTAssertFalse(first.isEmpty)
    XCTAssertNotNil(Data(base64Encoded: first))
    XCTAssertEqual(first, second)
  }

  /// 真实匹配接口需要外网，仅在人工验收时执行
  func testRecognizeActionReachesMatchService() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_RECOGNITION_NETWORK"] == "1" else {
      throw XCTSkip("真实识曲接口仅在人工验收时执行")
    }
    let pcm = Self.melody(seconds: 8)
    let fingerprint = try await NativeFingerprint.compute(pcm)
    let raw = try await NativeOnlineService().call([
      "action": "recognize", "fingerprint": fingerprint, "duration": Double(pcm.count) / 8000,
    ])
    XCTAssertNotNil(raw as? [[String: Any]], "接口应返回候选数组：\(raw)")
  }

  /// 生成有音高变化的合成旋律，避免纯正弦波缺少可提取特征
  private static func melody(seconds: Int) -> [Float] {
    let notes: [Float] = [440, 494, 523, 587, 659, 587, 523, 494]
    return (0..<(8000 * seconds)).map { index in
      let note = notes[(index / 4000) % notes.count]
      let time = Float(index) / 8000
      return 0.3 * sin(2 * .pi * note * time) + 0.1 * sin(2 * .pi * note * 2 * time)
    }
  }
}
