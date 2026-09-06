import Foundation
import CryptoKit

/// 下载任务由串行代理队列管理；四路分段落盘，合并时只保留 1 MB 缓冲。
final class IpaDownload: NSObject, URLSessionDownloadDelegate {
  private let url: URL
  private let size: Int64
  private let digest: String?
  private let directory: URL
  private let progress: (Int64, Int64, Double) -> Void
  private let completion: (Result<URL, Error>) -> Void
  private let queue: OperationQueue = {
    let value = OperationQueue()
    value.maxConcurrentOperationCount = 1
    return value
  }()
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 1800
    config.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }()
  private var tasks: [Int: (index: Int, start: Int64, end: Int64)] = [:]
  private var activeTasks: [Int: URLSessionDownloadTask] = [:]
  private var bytes: [Int: Int64] = [:]
  private var parts: [Int: URL] = [:]
  private var ranged = true
  private var finished = false
  private var lastTime = ProcessInfo.processInfo.systemUptime
  private var lastBytes: Int64 = 0

  init(url: URL, size: Int64, digest: String?, directory: URL,
       progress: @escaping (Int64, Int64, Double) -> Void,
       completion: @escaping (Result<URL, Error>) -> Void) {
    self.url = url
    self.size = size
    self.digest = digest
    self.directory = directory
    self.progress = progress
    self.completion = completion
  }

  func start() {
    queue.addOperation {
      do {
        guard self.size >= 22 else { throw self.failure("IPA 大小无效") }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // 先验证首段，服务器忽略 Range 时切换单连接，避免同时下载四份完整文件。
        self.launch(index: 0, start: 0, end: 0)
      } catch { self.finish(.failure(error)) }
    }
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "IpaDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func launch(index: Int, start: Int64, end: Int64) {
    var request = URLRequest(url: url)
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if ranged { request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range") }
    let task = session.downloadTask(with: request)
    tasks[task.taskIdentifier] = (index, start, end)
    activeTasks[task.taskIdentifier] = task
    task.resume()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    guard !finished, let part = tasks[downloadTask.taskIdentifier] else { return }
    let response = downloadTask.response as? HTTPURLResponse
    if ranged && response?.statusCode == 200 {
      fallback()
      return
    }
    let maximum = ranged ? part.end - part.start + 1 : size
    guard totalBytesWritten <= maximum else {
      finish(.failure(failure("下载内容超过预期大小")))
      return
    }
    // 探测的一字节不计入真正下载进度。
    if ranged && part.end == 0 { return }
    bytes[part.index] = totalBytesWritten
    let total = bytes.values.reduce(0, +)
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastTime >= 0.25 {
      progress(total, size, Double(max(0, total - lastBytes)) / (now - lastTime))
      lastTime = now
      lastBytes = total
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    guard !finished, let part = tasks[downloadTask.taskIdentifier] else { return }
    do {
      guard let response = downloadTask.response as? HTTPURLResponse else { throw failure("无效下载响应") }
      if ranged && response.statusCode == 200 { fallback(); return }
      if ranged {
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(part.start)-\(part.end)/\(size)"
        else { throw failure("服务器返回了错误的下载分段") }
      } else if response.statusCode != 200 { throw failure("下载失败 HTTP \(response.statusCode)") }
      let actual = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
      guard actual == (ranged ? part.end - part.start + 1 : size) else { throw failure("IPA 下载不完整") }
      tasks.removeValue(forKey: downloadTask.taskIdentifier)
      activeTasks.removeValue(forKey: downloadTask.taskIdentifier)
      if ranged && part.end == 0 {
        let chunk = (size + 3) / 4
        for index in 0..<4 {
          let start = Int64(index) * chunk
          if start < size { launch(index: index, start: start, end: min(size - 1, start + chunk - 1)) }
        }
        return
      }
      let destination = directory.appendingPathComponent("part-\(part.index)")
      try FileManager.default.moveItem(at: location, to: destination)
      parts[part.index] = destination
      bytes[part.index] = actual
      if tasks.isEmpty { try merge() }
    } catch { finish(.failure(error)) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if !finished, tasks[task.taskIdentifier] != nil, let error = error { finish(.failure(error)) }
  }

  private func merge() throws {
    let result = directory.appendingPathComponent("SPlayer-Next-iOS-unsigned.ipa")
    guard FileManager.default.createFile(atPath: result.path, contents: nil) else { throw failure("无法创建 IPA 文件") }
    let output = try FileHandle(forWritingTo: result)
    defer { try? output.close() }
    var hash = SHA256()
    var total: Int64 = 0
    for index in parts.keys.sorted() {
      let input = try FileHandle(forReadingFrom: parts[index]!)
      defer { try? input.close() }
      while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
        if total == 0 && !data.starts(with: [0x50, 0x4b, 0x03, 0x04]) { throw failure("下载文件不是 IPA/ZIP") }
        try output.write(contentsOf: data)
        hash.update(data: data)
        total += Int64(data.count)
      }
    }
    guard total == size else { throw failure("合并后的 IPA 大小不符") }
    if let digest = digest {
      let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
      guard actual == digest.replacingOccurrences(of: "sha256:", with: "").lowercased() else {
        throw failure("IPA SHA-256 校验失败，请重新下载")
      }
    }
    try output.synchronize()
    progress(size, size, 0)
    finish(.success(result))
  }

  private func fallback() {
    ranged = false
    activeTasks.values.forEach { $0.cancel() }
    activeTasks.removeAll()
    tasks.removeAll()
    for part in parts.values { try? FileManager.default.removeItem(at: part) }
    parts.removeAll()
    bytes.removeAll()
    lastBytes = 0
    lastTime = ProcessInfo.processInfo.systemUptime
    launch(index: 0, start: 0, end: size - 1)
  }

  private func finish(_ result: Result<URL, Error>) {
    guard !finished else { return }
    finished = true
    session.invalidateAndCancel()
    for part in parts.values { try? FileManager.default.removeItem(at: part) }
    if case .success = result {
      // 枚举 URL 的基址、尾斜杠可能不同，按同级 UUID 名称排除当前下载目录。
      let root = directory.deletingLastPathComponent()
      for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        if old.lastPathComponent != directory.lastPathComponent,
           UUID(uuidString: old.lastPathComponent) != nil {
          try? FileManager.default.removeItem(at: old)
        }
      }
    }
    if case .failure = result { try? FileManager.default.removeItem(at: directory) }
    completion(result)
  }
}
