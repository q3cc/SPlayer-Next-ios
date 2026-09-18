import CryptoKit
import Foundation
import Tauri
import UIKit

private struct CloudFileRequest: Decodable {
  let source: String
}

struct CloudTransferRequest: Decodable {
  let source: String
  let uploadId: String
  let url: String
  let token: String
  let md5: String
  let mime: String
  let size: Int64
}

/** 仅接受选择器复制到应用沙盒中的音频，拒绝目录和沙盒外路径。 */
private func cloudFileURL(_ source: String) throws -> URL {
  let parsed = source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(string: source)
  guard let parsed, parsed.isFileURL else {
    throw NSError(domain: "CloudUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择本地音频文件"])
  }
  let url = parsed.resolvingSymlinksInPath().standardizedFileURL
  let root = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
  let extensions = ["mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "wma", "ape", "aiff"]
  guard url.path.hasPrefix(root + "/"), extensions.contains(url.pathExtension.lowercased()),
        try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
    throw NSError(domain: "CloudUpload", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取所选音频，请重新选择"])
  }
  return url
}

extension NativeAudioPlugin {
  @objc func prepareCloudUpload(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(CloudFileRequest.self)
    DispatchQueue.global(qos: .utility).async {
      do {
        let url = try cloudFileURL(args.source)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = Insecure.MD5()
        var size: Int64 = 0
        // 按块哈希，不映射整首音频，避免无损文件导致内存峰值。
        while true {
          let count = try autoreleasepool { () throws -> Int in
            guard let bytes = try file.read(upToCount: 64 * 1024), !bytes.isEmpty else { return 0 }
            hash.update(data: bytes)
            return bytes.count
          }
          if count == 0 { break }
          size += Int64(count)
        }
        guard size > 0 else { invoke.reject("音频文件为空"); return }
        let md5 = hash.finalize().map { byte in String(format: "%02x", byte) }.joined()
        invoke.resolve(["md5": md5, "size": Double(size)])
      } catch { invoke.reject("读取音频失败，请重新选择文件") }
    }
  }

  @objc func uploadCloudFile(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(CloudTransferRequest.self)
    DispatchQueue.main.async {
      self.cloudUploader.start(args, invoke: invoke) { [weak self] loaded, total in
        guard UIApplication.shared.applicationState == .active else { return }
        self?.trigger("cloudUploadProgress", data: [
          "uploadId": args.uploadId, "stage": "uploading", "loaded": Double(loaded), "total": Double(total)
        ])
      }
    }
  }
}

/** 系统从磁盘读取请求体；会话结束即释放，不保留音频或响应体。 */
final class CloudUploader: NSObject, URLSessionTaskDelegate {
  private var session: URLSession?
  private var invocation: Invoke?
  private var progress: ((Int64, Int64) -> Void)?
  private var lastProgress: TimeInterval = 0

  func start(_ args: CloudTransferRequest, invoke: Invoke, onProgress: @escaping (Int64, Int64) -> Void) {
    guard session == nil else { invoke.reject("已有歌曲正在上传，请稍后重试"); return }
    do {
      let file = try cloudFileURL(args.source)
      guard let url = URL(string: args.url), url.scheme == "https",
            let host = url.host?.lowercased(), host.hasSuffix(".127.net"),
            url.user == nil, url.password == nil, url.fragment == nil else {
        invoke.reject("上传地址无效"); return
      }
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
      guard size == Int(args.size), args.size > 0 else {
        invoke.reject("音频文件已发生变化，请重新选择"); return
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(args.token, forHTTPHeaderField: "x-nos-token")
      request.setValue(args.md5, forHTTPHeaderField: "Content-MD5")
      request.setValue(args.mime, forHTTPHeaderField: "Content-Type")
      request.setValue(String(args.size), forHTTPHeaderField: "Content-Length")
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 300
      configuration.timeoutIntervalForResource = 1800
      configuration.httpCookieStorage = nil
      configuration.urlCache = nil
      invocation = invoke
      progress = onProgress
      lastProgress = 0
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
      self.session = session
      session.uploadTask(with: request, fromFile: file).resume()
    } catch { invoke.reject("无法读取所选音频，请重新选择") }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    let now = Date.timeIntervalSinceReferenceDate
    if now - lastProgress >= 0.2 || (totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend) {
      lastProgress = now
      progress?(totalBytesSent, totalBytesExpectedToSend)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    // 不允许重定向把上传授权和文件发送到其他服务。
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let invoke = invocation
    invocation = nil
    progress = nil
    self.session = nil
    session.finishTasksAndInvalidate()
    if error != nil { invoke?.reject("音频上传失败，请检查网络后重试"); return }
    guard let status = (task.response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
      invoke?.reject("上传服务器拒绝了文件"); return
    }
    invoke?.resolve(["success": true])
  }
}
