import Foundation
import Intents
import MediaPlayer
import ObjectiveC
import UIKit

/// 使用系统公开的应用内媒体意图回调，不替换 Tauri 已有的生命周期方法。
final class SiriMediaHandler: NSObject, INPlayMediaIntentHandling {

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
        let service = SiriService.shared
        if let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaSearch?.mediaIdentifier, !identifier.isEmpty {
          guard let track = service.selection.track(identifier, queue: service.queue.tracks) else {
            completion([.unsupported()]); return
          }
          completion([.success(with: INMediaItem(identifier: identifier,
            title: track["title"] as? String, type: .song, artwork: nil))]); return
        }
        var matches: [[String: Any]]
        let query = intent.mediaSearch?.mediaName ?? ""
        let artist = intent.mediaSearch?.artistName ?? ""
        if query.isEmpty && artist.isEmpty {
          if let current = SiriService.shared.queue.current { matches = [current] }
          else { completion([.needsValue()]); return }
        } else { matches = try await SiriService.shared.search(query: query, artist: artist) }
        guard !matches.isEmpty else { completion([.unsupported()]); return }
        matches = Array(matches.prefix(3))
        let items = matches.map { track in
          INMediaItem(identifier: SiriQueue.key(track), title: track["title"] as? String, type: .song,
            artwork: nil, artist: (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / "))
        }
        if items.count > 1 && service.needsConfirmation && service.askBeforePlaying { completion([.disambiguation(with: items)]) }
        else { completion([.success(with: items[0])]) }
      } catch { completion([.unsupported()]) }
    }
  }

  func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
    Task { @MainActor in
      do {
        let service = SiriService.shared
        let request = try service.selection.command(identifier: intent.mediaItems?.first?.identifier ?? intent.mediaSearch?.mediaIdentifier,
          hasMediaItems: !(intent.mediaItems ?? []).isEmpty,
          query: intent.mediaSearch?.mediaName ?? "", artist: intent.mediaSearch?.artistName ?? "",
          queue: service.queue.tracks)
        let result = try await service.execute(request)
        if result["choices"] != nil { throw SiriFailure("请重新选择要播放的歌曲") }
        let response = INPlayMediaIntentResponse(code: .success, userActivity: nil)
        if let track = service.queue.current { response.nowPlayingInfo = Self.nowPlaying(track, playing: service.queue.playing) }
        completion(response)
      } catch {
        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
      }
    }
  }

  func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
    Task { @MainActor in
      let service = SiriService.shared
      do {
        let request = try service.selection.command(identifier: intent.mediaItems?.first?.identifier ?? intent.mediaSearch?.mediaIdentifier,
          hasMediaItems: !(intent.mediaItems ?? []).isEmpty,
          query: intent.mediaSearch?.mediaName ?? "", artist: intent.mediaSearch?.artistName ?? "",
          queue: service.queue.tracks)
        let response = INPlayMediaIntentResponse(code: .ready, userActivity: nil)
        if let track = request["track"] as? [String: Any] {
          response.nowPlayingInfo = Self.nowPlaying(track, playing: false)
        } else if request["action"] as? String == "resume", let track = service.queue.current {
          response.nowPlayingInfo = Self.nowPlaying(track, playing: service.queue.playing)
        }
        completion(response)
      } catch { completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil)) }
    }
  }

  private static func nowPlaying(_ track: [String: Any], playing: Bool) -> [String: Any] {
    var info: [String: Any] = [MPMediaItemPropertyTitle: track["title"] as? String ?? "",
      MPMediaItemPropertyArtist: (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / "),
      MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
    if let duration = track["duration"] as? Double { info[MPMediaItemPropertyPlaybackDuration] = duration / 1000 }
    if let cover = track["cover"] as? String, let url = URL(string: cover), ["https", "http"].contains(url.scheme ?? "") {
      info[MPMediaItemPropertyArtwork] = INImage(url: url)
    }
    return info
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
