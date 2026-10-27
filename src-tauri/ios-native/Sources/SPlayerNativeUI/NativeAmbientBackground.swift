import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 模糊背景与 AMLL 原版流体算法共用缩略图，隐藏时停止渲染
struct NativeAmbientBackground: View {
  let cover: String?
  let playing: Bool
  var coverColors = NativeCoverColors()
  var bassVolume: Double = 0.1
  @AppStorage("native.player.background") private var mode = "blur"
  @AppStorage("native.player.flowSpeed") private var flowSpeed = 4.0
  @AppStorage("native.player.renderScale") private var renderScale = 0.5
  @AppStorage("native.player.fps") private var fps = 30.0
  @AppStorage("native.player.freezeOnPause") private var freezeOnPause = false
  @State private var mesh: NativeFluidMesh?
  @State private var meshID = ""
  @State private var failure: String?
  @State private var blurredImage: CGImage?
  @Environment(\.scenePhase) private var phase
  @NativeReduceMotion private var reduceMotion
  @State private var colors: [Color] = Self.defaultColors
  private static let defaultColors: [Color] = [
    .init(red: 0.26, green: 0.23, blue: 0.32), .init(red: 0.12, green: 0.14, blue: 0.22),
    .init(red: 0.30, green: 0.19, blue: 0.23), .init(red: 0.14, green: 0.20, blue: 0.26),
  ]
  var body: some View {
    ZStack {
      Color.black
      if mode == "blur" {
        GeometryReader { geometry in
          if let blurredImage {
            Image(decorative: blurredImage, scale: 1).resizable().scaledToFill()
              .frame(width: geometry.size.width, height: geometry.size.height)
              .scaleEffect(1.5).clipped()
          } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
          }
        }.overlay(Color.black.opacity(0.5))
      } else {
        if mode == "solid" {
          coverColors.base.overlay(Color.black.opacity(0.5))
        } else {
          #if os(iOS)
            if let mesh {
              NativeFluidBackground(
                mesh: mesh, identity: meshID, active: phase == .active,
                moving: !reduceMotion && (playing || !freezeOnPause), fps: Int(fps),
                speed: flowSpeed, scale: renderScale, volume: bassVolume, failure: $failure)
            }
          #endif
          if let failure { Text(failure).font(.caption).foregroundStyle(.white) }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea().allowsHitTesting(false)
      .task(id: "\(cover ?? "")-\(mode)") {
        guard
          let image = await NativeArtworkCache.shared.image(
            (cover?.isEmpty == false ? cover! : "native-default-cover"), pixels: 300)
        else { return }
        let result = await Task.detached(priority: .utility) {
          (Self.sample(image), Self.blur(image))
        }.value
        if mode == "fluid" || mode == "animation" {
          do {
            let generated = try await Task.detached(priority: .utility) {
              try NativeFluidMesh.make(image: image)
            }.value
            guard !Task.isCancelled else { return }
            mesh = generated
            meshID = UUID().uuidString
            failure = nil
          } catch { failure = "流体渲染失败：\(error.localizedDescription)" }
        } else {
          mesh = nil
        }
        let palette = result.0
        if !Task.isCancelled {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) {
            colors = palette
            blurredImage = result.1
          }
        }
      }
  }

  /// 在 300px 缩略图上预计算模糊与饱和度，不创建全屏实时模糊层
  nonisolated private static func blur(_ image: CGImage) -> CGImage? {
    let input = CIImage(cgImage: image)
    let color = CIFilter.colorControls()
    color.inputImage = input.clampedToExtent()
    color.saturation = 1.2
    let filter = CIFilter.gaussianBlur()
    filter.inputImage = color.outputImage
    filter.radius = 8
    guard let output = filter.outputImage else { return nil }
    return CIContext(options: [.cacheIntermediates: false]).createCGImage(
      output, from: input.extent)
  }

  /// Core Image 将四个象限分别缩为单像素，不在内存保留全尺寸封面
  nonisolated private static func sample(_ image: CGImage) -> [Color] {
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
