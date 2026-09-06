import Foundation
import UIKit
import Tauri

private struct DownloadRequest: Decodable {
  let url: String
  let size: Int64
  let digest: String?
}

final class IpaUpdatePlugin: Plugin {
  private var downloadTask: IpaDownload?
  private var downloaded: URL?

  @objc func download(_ invoke: Invoke) throws {
    let request = try invoke.parseArgs(DownloadRequest.self)
    DispatchQueue.main.async {
      guard self.downloadTask == nil else { invoke.reject("已有 IPA 下载任务"); return }
      guard let url = URL(string: request.url), url.scheme == "https", url.host == "github.com",
            url.path.hasPrefix("/q3cc/SPlayer-Next-ios/releases/download/"), url.path.hasSuffix(".ipa")
      else { invoke.reject("仅允许下载当前仓库的 IPA"); return }
      let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IpaUpdates", isDirectory: true)
      let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let task = IpaDownload(url: url, size: request.size, digest: request.digest, directory: folder,
        progress: { received, total, speed in
          DispatchQueue.main.async {
            let event: JSObject = ["percent": Double(received) / Double(total) * 100,
              "downloadedBytes": Double(received), "totalBytes": Double(total), "bytesPerSecond": speed]
            self.trigger("progress", data: event)
          }
        }, completion: { result in
          DispatchQueue.main.async {
            self.downloadTask = nil
            switch result {
            case .success(let file):
              guard FileManager.default.isReadableFile(atPath: file.path) else {
                invoke.reject("下载文件已丢失，请重新下载"); return
              }
              self.downloaded = file
              invoke.resolve()
            case .failure(let error): invoke.reject(error.localizedDescription)
            }
          }
        })
      self.downloadTask = task
      task.start()
    }
  }

  @objc func share(_ invoke: Invoke) {
    DispatchQueue.main.async {
      guard let file = self.downloaded, FileManager.default.fileExists(atPath: file.path) else {
        self.downloaded = nil
        invoke.reject("下载文件已丢失，请重新下载", code: "IPA_MISSING"); return
      }
      guard UIApplication.shared.applicationState == .active else {
        invoke.reject("请返回 App 后选择其他 App 打开"); return
      }
      // 多窗口与前台调度下，插件持有的控制器未必是当前可见窗口。
      let ownWindow = self.manager.viewController?.viewIfLoaded?.window
      let activeWindow = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
      let window = ownWindow?.windowScene?.activationState == .foregroundActive ? ownWindow : activeWindow
      guard var presenter = window?.rootViewController else {
        invoke.reject("找不到前台窗口，请返回 App 后重试"); return
      }
      while let next = presenter.presentedViewController { presenter = next }
      guard !(presenter is UIActivityViewController) else { invoke.resolve(); return }
      guard presenter.viewIfLoaded?.window != nil,
            !presenter.isBeingDismissed, !presenter.isBeingPresented else {
        invoke.reject("窗口正在切换，请稍后再次点击其他 App 打开"); return
      }
      let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }
      presenter.present(sheet, animated: true) {
        guard sheet.presentingViewController != nil else {
          invoke.reject("系统未能显示分享面板，请重试"); return
        }
        invoke.resolve()
      }
    }
  }
}

@_cdecl("init_plugin_ipa_update")
func initIpaUpdatePlugin() -> Plugin { IpaUpdatePlugin() }
