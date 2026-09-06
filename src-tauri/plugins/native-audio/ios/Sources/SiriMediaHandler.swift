import Foundation
import Intents
import ObjectiveC
import UIKit

/// 使用系统公开的应用内媒体意图回调，不替换 Tauri 已有的生命周期方法。
final class SiriMediaHandler: NSObject, INPlayMediaIntentHandling {
  private var matches: [[String: Any]] = []

  @MainActor static func install() {
    guard let type = NSClassFromString("AppDelegate") else { return }
    let selector = NSSelectorFromString("application:handlerForIntent:")
    guard class_getInstanceMethod(type, selector) == nil else { return }
    let block: @convention(block) (AnyObject, UIApplication, INIntent) -> AnyObject? = { _, _, intent in
      intent is INPlayMediaIntent ? SiriMediaHandler() : nil
    }
    class_addMethod(type, selector, imp_implementationWithBlock(block), "@@:@@")
  }

  func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
    Task { @MainActor in
      do {
        let query = intent.mediaSearch?.mediaName ?? ""
        let artist = intent.mediaSearch?.artistName ?? ""
        if query.isEmpty && artist.isEmpty {
          if let current = SiriService.shared.queue.current { matches = [current] }
          else { completion([.needsValue()]); return }
        } else { matches = try await SiriService.shared.search(query: query, artist: artist) }
        guard !matches.isEmpty else { completion([.unsupported()]); return }
        matches = Array(matches.prefix(5))
        let items = matches.map { track in
          INMediaItem(identifier: SiriQueue.key(track), title: track["title"] as? String, type: .song,
            artwork: nil, artist: (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / "))
        }
        if items.count > 1 && SiriService.shared.askBeforePlaying { completion([.disambiguation(with: items)]) }
        else { completion([.success(with: items[0])]) }
      } catch { completion([.unsupported()]) }
    }
  }

  func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
    Task { @MainActor in
      do {
        if let identifier = intent.mediaItems?.first?.identifier,
          let track = (matches + SiriService.shared.queue.tracks).first(where: { SiriQueue.key($0) == identifier }) {
          _ = try await SiriService.shared.execute(["action": "playTrack", "track": track])
        } else {
          let query = intent.mediaSearch?.mediaName ?? ""
          let artist = intent.mediaSearch?.artistName ?? ""
          if query.isEmpty && artist.isEmpty { _ = try await SiriService.shared.execute(["action": "resume"]) }
          else {
            let result = try await SiriService.shared.execute(["action": "playQuery", "query": query, "artist": artist])
            if result["choices"] != nil { throw SiriFailure("请重新选择要播放的歌曲") }
          }
        }
        matches = []
        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
      } catch {
        matches = []
        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
      }
    }
  }
}

/// App Intents 编译在应用主目标，通过稳定的 C 接口调用同一个原生播放器。
@_cdecl("splayer_siri_execute")
func executeSiriCommand(_ request: UnsafePointer<CChar>?, _ opaque: UnsafeMutableRawPointer?,
  _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void) {
  let text = request.map { String(cString: $0) } ?? "{}"
  Task { @MainActor in
    let response: [String: Any]
    do {
      guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw SiriFailure("无效的语音请求") }
      response = ["ok": true, "data": try await SiriService.shared.execute(value)]
    } catch { response = ["ok": false, "error": error.localizedDescription] }
    let json = String(data: try! JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
    json.withCString { callback(opaque, $0) }
  }
}
