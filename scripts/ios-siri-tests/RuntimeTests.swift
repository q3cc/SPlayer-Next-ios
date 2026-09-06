import Foundation

@main
struct RuntimeTests {
  static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let track: [String: Any] = ["id": "local-one", "source": "local", "title": "晴天",
      "artists": [["id": "jay", "name": "周杰伦"]], "path": "/tmp/siri-test.mp3"]
    let search: [String: Any] = ["action": "search", "query": "晴 天", "artist": "周杰伦",
      "source": "netease", "scope": "local", "library": [track], "quality": "hq", "allowTrial": false]
    let result = try await SiriRuntime(resourceDirectory: directory).run(search, storage: [:])
    let tracks = (result["value"] as? [String: Any])?["tracks"] as? [[String: Any]] ?? []
    precondition(tracks.count == 1 && tracks[0]["id"] as? String == "local-one")
    var resolve = search
    resolve["action"] = "resolve"
    resolve["track"] = track
    let resolved = try await SiriRuntime(resourceDirectory: directory).run(resolve, storage: [:])
    precondition((resolved["value"] as? [String: Any])?["url"] as? String == "/tmp/siri-test.mp3")
    var empty = search
    empty["query"] = ""
    empty["artist"] = ""
    do {
      _ = try await SiriRuntime(resourceDirectory: directory).run(empty, storage: [:])
      fatalError("空搜索应拒绝")
    } catch { precondition(error.localizedDescription.contains("歌名或歌手")) }
    print("PASS: JavaScriptCore 实际运行共享后台模块、本地搜索、地址解析与错误回传")
  }
}
