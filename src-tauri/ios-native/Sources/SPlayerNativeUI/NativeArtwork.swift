import ImageIO
import SwiftUI

/// 图片按展示尺寸解码，缓存有数量和内存上限
actor NativeArtworkCache {
  static let shared = NativeArtworkCache()
  /// NSCache 自身线程安全，允许同步读取已解码的封面
  nonisolated(unsafe) private let cache = NSCache<NSString, NativeImageBox>()
  /// 建立有容量限制的封面缓存及图像所有权
  init() {
    cache.countLimit = 80
    cache.totalCostLimit = 24 * 1024 * 1024
  }
  /// 同步读取已缓存的封面，视图挂载时直接显示，不等待一次异步往返
  /// @param value - 封面地址
  /// @param pixels - 解码尺寸
  /// @returns 已缓存的图片
  nonisolated func cached(_ value: String, pixels: Int) -> CGImage? {
    cache.object(forKey: (value + "#\(pixels)") as NSString)?.image
  }

  /// 按目标像素尺寸解码封面，并使用有界内存缓存
  func image(_ value: String, pixels: Int) async -> CGImage? {
    let key = (value + "#\(pixels)") as NSString
    if let image = cache.object(forKey: key) { return image.image }
    let url: URL
    if value == "native-default-cover" {
      guard let resource = Bundle.module.url(forResource: "DefaultSong", withExtension: "jpg")
      else { return nil }
      url = resource
    } else if value.hasPrefix("native-cover:") {
      let name = String(value.dropFirst(13))
      guard URL(fileURLWithPath: name).lastPathComponent == name, !name.hasPrefix(".") else {
        return nil
      }
      url = NativeLibrary.defaultRoot().appendingPathComponent(name)
    } else {
      guard let remote = URL(string: value), ["http", "https"].contains(remote.scheme ?? "") else {
        return nil
      }
      url = remote
    }
    let data: Data
    do {
      if url.isFileURL {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024
        else { return nil }
        data = try Data(contentsOf: url)
      } else {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 整体读取后再校验大小；逐字节读取会让缓存查询排在下载之后
        let (body, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, body.count <= 8 * 1024 * 1024
        else { return nil }
        data = body
      }
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { return nil }
      cache.setObject(NativeImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
      return image
    } catch { return nil }
  }
}
private final class NativeImageBox {
  let image: CGImage
  /// 建立有容量限制的封面缓存及图像所有权
  init(_ image: CGImage) { self.image = image }
}

struct NativeArtwork: View {
  let cover: String?
  var radius: CGFloat = 8
  var pixels = 300
  /// 大图加载前先显示的缩略图尺寸；共享过渡落地时不出现空白占位
  var preview: Int? = nil
  @State private var image: CGImage?

  init(cover: String?, radius: CGFloat = 8, pixels: Int = 300, preview: Int? = nil) {
    self.cover = cover
    self.radius = radius
    self.pixels = pixels
    self.preview = preview
    _image = State(initialValue: Self.cached(cover, pixels: pixels, preview: preview))
  }

  private static func source(_ cover: String?) -> String {
    (cover ?? "").isEmpty ? "native-default-cover" : cover ?? ""
  }

  private static func cached(_ cover: String?, pixels: Int, preview: Int?) -> CGImage? {
    let source = source(cover)
    return NativeArtworkCache.shared.cached(source, pixels: pixels)
      ?? preview.flatMap { NativeArtworkCache.shared.cached(source, pixels: $0) }
  }
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.primary.opacity(0.055)
        if let image {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
      }.clipShape(RoundedRectangle(cornerRadius: radius))
    }.task(id: cover) {
      let source = Self.source(cover)
      if let full = NativeArtworkCache.shared.cached(source, pixels: pixels) {
        image = full
        return
      }
      image = preview.flatMap { NativeArtworkCache.shared.cached(source, pixels: $0) }
      if let preview, preview < pixels, image == nil {
        let small = await NativeArtworkCache.shared.image(source, pixels: preview)
        if Task.isCancelled { return }
        image = small
      }
      let loaded = await NativeArtworkCache.shared.image(source, pixels: pixels)
      if !Task.isCancelled, loaded != nil || image == nil { image = loaded }
    }.accessibilityHidden(true)
  }
}
