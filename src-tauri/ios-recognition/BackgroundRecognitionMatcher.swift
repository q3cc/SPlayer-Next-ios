import Foundation
import JavaScriptCore

final class BackgroundRecognitionMatcher {
  private let queue = DispatchQueue(label: "splayer.recognition.fingerprint")
  private var context: JSContext?
  private var task: URLSessionDataTask?
  private var cancelled = false

  func match(_ samples: [Float], completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    queue.async {
      guard !self.cancelled else { return }
      do {
        if self.context == nil {
          guard let context = JSContext(), let url = Bundle.main.url(forResource: "afp-runtime", withExtension: "js") else {
            throw self.failure("后台指纹模块未打包")
          }
          context.evaluateScript("var console = {log:function(){},warn:function(){}};")
          context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
          if let error = context.exception { throw self.failure(error.toString()) }
          self.context = context
        }
        guard let context = self.context else { return }
        context.exception = nil
        let value = context.objectForKeyedSubscript("recognitionFingerprint")?.call(withArguments: [samples])
        if let error = context.exception { throw self.failure(error.toString()) }
        guard let bytes = value?.toArray() as? [NSNumber], !bytes.isEmpty else {
          throw self.failure("后台音频指纹为空")
        }
        let fingerprint = Data(bytes.map { $0.uint8Value }).base64EncodedString()
        var url = URLComponents(string: "https://interface.music.163.com/api/music/audio/match")!
        url.queryItems = [
          URLQueryItem(name: "sessionId", value: UUID().uuidString),
          URLQueryItem(name: "algorithmCode", value: "shazam_v2"),
          URLQueryItem(name: "duration", value: String(Double(samples.count) / 8000)),
          URLQueryItem(name: "rawdata", value: fingerprint),
          URLQueryItem(name: "times", value: "1"), URLQueryItem(name: "decrypt", value: "1"),
        ]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: url.url!, timeoutInterval: 10)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        self.task = URLSession.shared.dataTask(with: request) { data, response, error in
          self.queue.async {
            guard !self.cancelled else { return }
            self.task = nil
            do {
              if let error = error { throw error }
              guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                    let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    body["code"] as? Int == 200 else { throw self.failure("识曲服务请求失败") }
              let payload = body["data"] as? [String: Any]
              let rows = payload?["result"] as? [[String: Any]] ?? []
              let candidates: [[String: Any]] = rows.prefix(3).compactMap { item in
                guard let song = item["song"] as? [String: Any], let id = song["id"] as? NSNumber,
                      let title = song["name"] as? String else { return nil }
                let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                let album = song["album"] as? [String: Any] ?? [:]
                return ["songId": id.stringValue, "title": title, "artists": artists,
                        "album": album["name"] as? String ?? "", "cover": album["picUrl"] as? String ?? ""]
              }
              completion(.success(candidates))
            } catch { completion(.failure(error)) }
          }
        }
        self.task?.resume()
      } catch { completion(.failure(error)) }
    }
  }

  func cancel() {
    queue.async {
      self.cancelled = true
      self.task?.cancel()
      self.task = nil
      self.context = nil
    }
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "SPlayerRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
