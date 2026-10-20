import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 从 300px 封面采样色彩，仅在播放页可见且播放中以 30fps 更新渐变
struct NativeAmbientBackground: View {
  let cover: String?
  let playing: Bool
  @Environment(\.scenePhase) private var phase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var colors: [Color] = Self.defaultColors
  private static let defaultColors: [Color] = [
    .init(red: 0.26, green: 0.23, blue: 0.32), .init(red: 0.12, green: 0.14, blue: 0.22),
    .init(red: 0.30, green: 0.19, blue: 0.23), .init(red: 0.14, green: 0.20, blue: 0.26),
  ]
  var body: some View {
    TimelineView(
      .animation(minimumInterval: 1.0 / 30, paused: !playing || phase != .active || reduceMotion)
    ) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      let shift = Float(sin(time / 8) * 0.13)
      #if compiler(>=6.0)
        if #available(iOS 18.0, macOS 15.0, *) {
          MeshGradient(
            width: 3, height: 3,
            points: [
              .init(0, 0), .init(0.5, 0), .init(1, 0), .init(0, 0.5),
              .init(0.5 + shift, 0.5 - shift), .init(1, 0.5), .init(0, 1), .init(0.5, 1),
              .init(1, 1),
            ],
            colors: [
              colors[0], colors[1], colors[2], colors[1], colors[2], colors[3], colors[2],
              colors[3], colors[0],
            ])
        } else {
          LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
      #else
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
      #endif
    }.overlay(Color.black.opacity(0.65)).ignoresSafeArea().allowsHitTesting(false)
      .task(id: cover) {
        colors = Self.defaultColors
        guard let cover, let image = await NativeArtworkCache.shared.image(cover, pixels: 300)
        else { return }
        let palette = await Task.detached(priority: .utility) { Self.sample(image) }.value
        if !Task.isCancelled { colors = palette }
      }
  }

  /// Core Image 将四个象限分别缩为单像素，不在内存保留全尺寸封面
  private static func sample(_ image: CGImage) -> [Color] {
    let input = CIImage(cgImage: image)
    let context = CIContext(options: [.cacheIntermediates: false])
    let width = input.extent.width / 2
    let height = input.extent.height / 2
    return [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { x, y in
      let filter = CIFilter.areaAverage()
      filter.inputImage = input
      filter.extent = CGRect(x: x * width, y: y * height, width: width, height: height)
      var pixel = [UInt8](repeating: 0, count: 4)
      if let output = filter.outputImage {
        context.render(
          output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
          format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
      }
      return Color(
        red: max(0.12, Double(pixel[0]) / 255), green: max(0.12, Double(pixel[1]) / 255),
        blue: max(0.12, Double(pixel[2]) / 255))
    }
  }
}
