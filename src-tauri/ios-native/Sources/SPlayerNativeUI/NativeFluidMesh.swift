import CoreGraphics
import Foundation
import JavaScriptCore

/// 直接运行 AMLL 0.5.2 的双三次 Hermite 网格与纹理算法，不模拟 DOM
struct NativeFluidMesh {
  let vertices: [Float]
  let indices: [UInt16]
  let pixels: [UInt8]

  /// 输入仅为 300px 缩略图；预设参数用于与上游确定性对照
  static func make(image: CGImage, preset: Int = -1) throws -> NativeFluidMesh {
    guard let context = JSContext(),
      let url = Bundle.module.url(forResource: "AMLLMesh", withExtension: "js")
    else { throw CocoaError(.fileReadNoSuchFile) }
    context.evaluateScript(try String(contentsOf: url))
    let module = context.objectForKeyedSubscript("NativeAMLL")!
    guard let mesh = module.invokeMethod("mesh", withArguments: [preset]),
      let vertices = mesh.forProperty("vertices").toArray() as? [NSNumber],
      let indices = mesh.forProperty("indices").toArray() as? [NSNumber]
    else { throw CocoaError(.coderReadCorrupt) }
    var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
    let bitmap = CGContext(
      data: &rgba, width: 32, height: 32, bitsPerComponent: 8,
      bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.interpolationQuality = .low
    bitmap.translateBy(x: 0, y: 32)
    bitmap.scaleBy(x: 1, y: -1)
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    guard
      let pixels = module.invokeMethod("texture", withArguments: [rgba])?.toArray() as? [NSNumber]
    else { throw CocoaError(.coderReadCorrupt) }
    return NativeFluidMesh(
      vertices: vertices.map(\.floatValue), indices: indices.map(\.uint16Value),
      pixels: pixels.map(\.uint8Value))
  }
}
