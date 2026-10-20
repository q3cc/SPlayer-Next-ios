import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI

/// 系统原生账号页；二维码由平台生成，登录会话仅保存在 Keychain
@MainActor
struct NativeAccountsView: View {
  let service: NativeOnlineService
  @State private var source = "netease"
  @State private var image: CGImage?
  @State private var message = ""
  @State private var nickname: String?
  @State private var loading = false
  @State private var task: Task<Void, Never>?
  @State private var generation = 0
  var body: some View {
    VStack(spacing: 24) {
      Picker("音乐平台", selection: $source) {
        Text("网易云").tag("netease")
        Text("QQ 音乐").tag("qqmusic")
        Text("酷狗").tag("kugou")
      }.pickerStyle(.segmented)
      Spacer()
      if let nickname {
        Image(systemName: "person.crop.circle.fill").font(.system(size: 72)).foregroundStyle(
          .secondary)
        Text(nickname).font(.title2.bold())
        Text("已登录").foregroundStyle(.secondary)
      } else {
        if let image {
          Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit().frame(
            width: 240, height: 240
          ).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
        } else if loading {
          ProgressView("正在获取二维码…")
        } else {
          Image(systemName: "qrcode").font(.system(size: 100)).foregroundStyle(.tertiary)
        }
        Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
        Button(image == nil ? "扫码登录" : "刷新二维码") { create() }.buttonStyle(.borderedProminent)
          .disabled(loading)
      }
      Spacer()
    }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity).navigationTitle("平台账号")
      .task(id: source) {
        task?.cancel()
        generation += 1
        loading = false
        image = nil
        message = "使用对应平台手机 App 扫码"
        nickname = nil
        do {
          let value =
            try await service.call(["action": "loginStatus", "source": source]) as? [String: Any]
          if !Task.isCancelled { nickname = value?["nickname"] as? String }
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
      }
      .onDisappear {
        task?.cancel()
        generation += 1
      }
  }

  /// 页面离开或平台切换立即取消轮询，过期后由用户明确刷新
  private func create() {
    task?.cancel()
    generation += 1
    let token = generation
    loading = true
    image = nil
    message = "正在获取二维码…"
    task = Task {
      defer { if token == generation { loading = false } }
      do {
        let value =
          try await service.call(["action": "loginCreate", "source": source]) as? [String: Any]
        guard token == generation, let key = value?["key"] as? String,
          let content = value?["content"] as? String
        else { return }
        image = Self.qrImage(content)
        guard image != nil else { throw SiriFailure("无法生成登录二维码") }
        loading = false
        message = "请用手机 App 扫码并确认登录"
        for _ in 0..<90 {
          try await Task.sleep(nanoseconds: 2_000_000_000)
          let result =
            try await service.call(["action": "loginCheck", "source": source, "key": key])
            as? [String: Any]
          guard token == generation, !Task.isCancelled else { return }
          switch result?["state"] as? String {
          case "success":
            nickname = result?["nickname"] as? String ?? "已登录用户"
            image = nil
            return
          case "expired":
            image = nil
            message = "二维码已过期，请重新获取"
            return
          case "scanned": message = "已扫码，请在手机上确认"
          default: break
          }
        }
        image = nil
        message = "二维码已过期，请重新获取"
      } catch is CancellationError {} catch {
        if token == generation {
          message = error.localizedDescription
          image = nil
        }
      }
    }
  }

  /// 平台返回图片时直接解码，否则使用 Core Image 生成不插值的二维码
  private static func qrImage(_ value: String) -> CGImage? {
    if value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
      let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    {
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
  }
}
