import AppIntents
import Foundation

@_silgen_name("splayer_siri_execute")
private func executeNative(_ request: UnsafePointer<CChar>?, _ opaque: UnsafeMutableRawPointer?,
  _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)

private final class SiriReply {
  let completion: CheckedContinuation<[String: Any], Error>
  init(_ completion: CheckedContinuation<[String: Any], Error>) { self.completion = completion }
}
private struct SiriError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private func execute(_ request: [String: Any]) async throws -> [String: Any] {
  let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
  return try await withCheckedThrowingContinuation { continuation in
    let reply = Unmanaged.passRetained(SiriReply(continuation)).toOpaque()
    json.withCString { text in
      executeNative(text, reply) { opaque, raw in
        guard let opaque = opaque else { return }
        let reply = Unmanaged<SiriReply>.fromOpaque(opaque).takeRetainedValue()
        do {
          let value = try JSONSerialization.jsonObject(with: Data((raw.map { String(cString: $0) } ?? "{}").utf8)) as? [String: Any] ?? [:]
          guard value["ok"] as? Bool == true else { throw SiriError(message: value["error"] as? String ?? "播放失败") }
          reply.completion.resume(returning: value["data"] as? [String: Any] ?? [:])
        } catch { reply.completion.resume(throwing: error) }
      }
    }
  }
}

struct PlaySPlayerIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "用 SPlayer 播放音乐"
  static var description = IntentDescription("按歌名搜索并播放音乐。")
  static var openAppWhenRun = false
  @Parameter(title: "歌名") var query: String
  func perform() async throws -> some IntentResult & ProvidesDialog {
    var result = try await execute(["action": "playQuery", "query": query])
    if let choices = result["choices"] as? [[String: Any]] {
      let labels = choices.enumerated().map { index, track in
        let artist = (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
        return "\(track["title"] as? String ?? "歌曲") · \(artist)（\(index + 1)）"
      }
      let selected = try await $query.requestDisambiguation(among: labels, dialog: "想播放哪一首？")
      guard let index = labels.firstIndex(of: selected) else { throw SiriError(message: "没有选择歌曲") }
      result = try await execute(["action": "playTrack", "track": choices[index]])
    }
    return .result(dialog: "\(result["message"] as? String ?? "已开始播放")")
  }
}

struct ResumeSPlayerIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "继续播放 SPlayer"
  static var openAppWhenRun = false
  func perform() async throws -> some IntentResult { _ = try await execute(["action": "resume"]); return .result() }
}
struct PauseSPlayerIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "暂停 SPlayer"
  static var openAppWhenRun = false
  func perform() async throws -> some IntentResult { _ = try await execute(["action": "pause"]); return .result() }
}
struct NextSPlayerIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "SPlayer 下一首"
  static var openAppWhenRun = false
  func perform() async throws -> some IntentResult { _ = try await execute(["action": "next"]); return .result() }
}
struct PreviousSPlayerIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "SPlayer 上一首"
  static var openAppWhenRun = false
  func perform() async throws -> some IntentResult { _ = try await execute(["action": "previous"]); return .result() }
}
struct SPlayerShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: PlaySPlayerIntent(), phrases: ["用\(.applicationName)播放音乐"], shortTitle: "播放音乐", systemImageName: "music.note")
    AppShortcut(intent: ResumeSPlayerIntent(), phrases: ["继续播放\(.applicationName)"], shortTitle: "继续播放", systemImageName: "play.fill")
    AppShortcut(intent: PauseSPlayerIntent(), phrases: ["暂停\(.applicationName)"], shortTitle: "暂停", systemImageName: "pause.fill")
    AppShortcut(intent: NextSPlayerIntent(), phrases: ["\(.applicationName)下一首"], shortTitle: "下一首", systemImageName: "forward.end.fill")
    AppShortcut(intent: PreviousSPlayerIntent(), phrases: ["\(.applicationName)上一首"], shortTitle: "上一首", systemImageName: "backward.end.fill")
  }
}
