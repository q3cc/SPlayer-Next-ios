import Foundation
import JavaScriptCore
import Security

/// 每次请求独立的后台 JS 环境；结束后释放网络任务、定时器和整个上下文。
final class SiriRuntime {
  private let queue = DispatchQueue(label: "top.imsyy.splayer.siri-js")
  private var context: JSContext?
  private var session: URLSession?
  private var timers: [Int: DispatchWorkItem] = [:]
  private var timerId = 0
  private var completion: ((Result<[String: Any], Error>) -> Void)?

  func cancel() { queue.async { self.finish(.failure(SiriFailure("已被新的播放操作取消"))) } }

  func run(_ request: [String: Any], storage: [String: String]) async throws -> [String: Any] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.completion = { continuation.resume(with: $0) }
        do {
          let context = JSContext()!
          self.context = context
          context.exceptionHandler = { [weak self] _, _ in self?.finish(.failure(SiriFailure("后台音乐接口执行失败"))) }
          context.setObject(storage, forKeyedSubscript: "__siriStorage" as NSString)
          let random: @convention(block) (Int) -> [UInt8] = { count in
            var bytes = [UInt8](repeating: 0, count: max(0, min(65536, count)))
            if !bytes.isEmpty { _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) }
            return bytes
          }
          context.setObject(random, forKeyedSubscript: "__siriRandom" as NSString)
          let bytes: @convention(block) (String) -> [UInt8] = { Array(Data(base64Encoded: $0) ?? Data()) }
          let utf8: @convention(block) (String) -> String = { String(data: Data(base64Encoded: $0) ?? Data(), encoding: .utf8) ?? "" }
          context.setObject(bytes, forKeyedSubscript: "__siriBytes" as NSString)
          context.setObject(utf8, forKeyedSubscript: "__siriUTF8" as NSString)
          let url: @convention(block) (String, String) -> String = { value, base in
            guard let parsed = URL(string: value, relativeTo: URL(string: base))?.absoluteURL else { return "{}" }
            let host = parsed.host ?? ""
            let port = parsed.port.map { ":\($0)" } ?? ""
            let json: [String: String] = ["href": parsed.absoluteString, "pathname": parsed.path,
              "search": parsed.query.map { "?\($0)" } ?? "", "hostname": host,
              "origin": "\(parsed.scheme ?? "https")://\(host)\(port)"]
            return String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
          }
          context.setObject(url, forKeyedSubscript: "__siriURL" as NSString)
          let timer: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, ms in
            guard let self = self, self.completion != nil else { return 0 }
            self.timerId += 1
            let id = self.timerId
            let work = DispatchWorkItem { [weak self] in
              guard let self = self, self.completion != nil else { return }
              self.timers.removeValue(forKey: id)
              callback.call(withArguments: [])
            }
            self.timers[id] = work
            self.queue.asyncAfter(deadline: .now() + max(0, ms) / 1000, execute: work)
            return id
          }
          let clear: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
          context.setObject(timer, forKeyedSubscript: "__siriTimer" as NSString)
          context.setObject(clear, forKeyedSubscript: "__siriClearTimer" as NSString)
          let configuration = URLSessionConfiguration.ephemeral
          configuration.httpCookieStorage = nil
          configuration.timeoutIntervalForResource = 20
          self.session = URLSession(configuration: configuration)
          let http: @convention(block) (String, String, String, String, Double, JSValue, JSValue) -> Void = {
            [weak self] url, method, headers, body, timeout, success, failure in
            guard let self = self, let address = URL(string: url), ["http", "https"].contains(address.scheme ?? "") else {
              failure.call(withArguments: ["无效的音乐接口地址"]); return
            }
            var request = URLRequest(url: address, timeoutInterval: max(1, min(20, timeout / 1000)))
            request.httpMethod = method
            request.allHTTPHeaderFields = (try? JSONSerialization.jsonObject(with: Data(headers.utf8))) as? [String: String]
            if !body.isEmpty { request.httpBody = Data(body.utf8) }
            self.session?.dataTask(with: request) { [weak self] data, response, error in
              self?.queue.async { [weak self] in
                guard let self = self, self.completion != nil else { return }
                guard error == nil, let response = response as? HTTPURLResponse, let data = data, data.count <= 8 * 1024 * 1024 else {
                  failure.call(withArguments: ["音乐接口网络请求失败"]); return
                }
                let headers = Dictionary(response.allHeaderFields.map { (String(describing: $0.key).lowercased(), String(describing: $0.value)) }, uniquingKeysWith: { _, next in next })
                let encoded = String(data: try! JSONSerialization.data(withJSONObject: headers), encoding: .utf8)!
                success.call(withArguments: [response.statusCode, encoded, data.base64EncodedString()])
              }
            }.resume()
          }
          context.setObject(http, forKeyedSubscript: "__siriHttp" as NSString)
          let done: @convention(block) (String) -> Void = { [weak self] text in
            guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
              self?.finish(.failure(SiriFailure("后台接口结果无效"))); return
            }
            self?.finish(.success(value))
          }
          let failed: @convention(block) (String) -> Void = { [weak self] message in self?.finish(.failure(SiriFailure(message))) }
          context.setObject(done, forKeyedSubscript: "__siriDone" as NSString)
          context.setObject(failed, forKeyedSubscript: "__siriFailed" as NSString)
          for name in ["siri-bootstrap", "siri-background"] {
            guard let file = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "assets/siri") else {
              throw SiriFailure("安装包缺少 Siri 后台模块")
            }
            context.evaluateScript(try String(contentsOf: file, encoding: .utf8))
            if self.completion == nil { return }
          }
          let input = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
          context.evaluateScript("SPlayerSiri.run(\(input)).then(value => __siriDone(JSON.stringify({value, storage: __siriStorage})), error => __siriFailed(String(error.message || error)))")
          self.queue.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finish(.failure(SiriFailure("Siri 音乐请求超时，请稍后重试"))) }
        } catch { self.finish(.failure(error)) }
      }
    }
  }

  private func finish(_ result: Result<[String: Any], Error>) {
    guard let callback = completion else { return }
    completion = nil
    session?.invalidateAndCancel(); session = nil
    for timer in timers.values { timer.cancel() }
    timers.removeAll()
    context = nil
    callback(result)
  }
}
