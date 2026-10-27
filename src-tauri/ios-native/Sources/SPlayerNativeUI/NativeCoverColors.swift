import CoreGraphics
import Foundation
import JavaScriptCore
import SwiftUI

/// 执行 Next 的 64px 加权采样、Celebi 量化和 HCT 评分
struct NativeCoverColors {
  var base: Color = Color(red: 20 / 255, green: 20 / 255, blue: 28 / 255)
  var foreground: Color = Color(red: 239 / 255, green: 239 / 255, blue: 239 / 255)

  /// 只处理封面缩略图，计算完成后释放 JS 上下文和像素数组
  static func extract(_ image: CGImage) throws -> NativeCoverColors {
    guard let context = JSContext(),
      let url = Bundle.module.url(forResource: "NextCoverColors", withExtension: "js")
    else { throw CocoaError(.fileReadNoSuchFile) }
    context.evaluateScript(try String(contentsOf: url))
    var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
    guard
      let bitmap = CGContext(
        data: &rgba, width: 64, height: 64, bitsPerComponent: 8,
        bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.coderReadCorrupt) }
    bitmap.interpolationQuality = .low
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    let result = context.objectForKeyedSubscript("NativeCoverColors")?.invokeMethod(
      "colors", withArguments: [rgba])
    if let error = context.exception {
      throw NSError(
        domain: "NextCoverColors", code: 1,
        userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "封面取色失败"])
    }
    guard let result, !result.isNull, !result.isUndefined else { return NativeCoverColors() }
    guard let base = result.forProperty("base")?.toString(),
      let foreground = result.forProperty("foreground")?.toString(),
      let b = hex(base), let f = hex(foreground)
    else { return NativeCoverColors() }
    return NativeCoverColors(base: b, foreground: f)
  }
  /// 仅接受原算法输出的六位 HEX 颜色
  private static func hex(_ text: String) -> Color? {
    guard text.count == 7, text.first == "#", let n = UInt32(text.dropFirst(), radix: 16) else {
      return nil
    }
    return Color(
      red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255,
      blue: Double(n & 255) / 255)
  }
}
