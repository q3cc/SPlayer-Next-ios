import Foundation

let first: [String: Any] = ["id": "one", "source": "local", "title": "第一首"]
let second: [String: Any] = ["id": "two", "source": "netease", "title": "第二首"]
let queue = SiriQueue()
precondition(queue.replace(["revision": 0, "queue": [first, second], "currentId": "local:one", "position": 5000.0]))
precondition(queue.revision == 1)
let next = try queue.neighbor(1)
precondition(SiriQueue.key(next) == "netease:two")
queue.select(second)
precondition(queue.revision == 2)
precondition(!queue.replace(["revision": 1, "queue": [first], "currentId": "local:one"]))
precondition(queue.currentKey == "netease:two", "旧网页快照不能覆盖 Siri 切歌")
queue.position = 12345
queue.playing = true
let encoded = try JSONSerialization.data(withJSONObject: queue.json)
let restored = SiriQueue()
restored.restore(try JSONSerialization.jsonObject(with: encoded) as! [String: Any])
precondition(restored.currentKey == queue.currentKey)
precondition(restored.position == 12345)
precondition(!restored.playing, "冷启动不能未经命令自动播放")
let restoredNext = try restored.neighbor(1)
let restoredPrevious = try restored.neighbor(-1)
precondition(SiriQueue.key(restoredNext) == "local:one")
precondition(SiriQueue.key(restoredPrevious) == "local:one")
print("PASS: 原生队列版本冲突、切歌和冷启动恢复")

let checkpointQueue = SiriQueue()
precondition(checkpointQueue.replace(["revision": 0, "queue": [first, second], "currentId": "local:one", "position": 1000.0]))
precondition(!checkpointQueue.checkpoint(trackId: "netease:two", position: 65000, playing: true))
precondition(!checkpointQueue.checkpoint(trackId: nil, position: 65000, playing: true))
precondition(!checkpointQueue.checkpoint(trackId: "local:one", position: .nan, playing: true))
precondition(!checkpointQueue.checkpoint(trackId: "local:one", position: -1, playing: true))
precondition(checkpointQueue.position == 1000, "错歌与无效断点不能覆盖已保存的进度")
precondition(checkpointQueue.checkpoint(trackId: "local:one", position: 65000, playing: true))
precondition(checkpointQueue.position == 65000 && checkpointQueue.playing)
let checkpointRestored = SiriQueue()
checkpointRestored.restore(checkpointQueue.json)
precondition(checkpointRestored.position == 65000 && !checkpointRestored.playing)
checkpointQueue.select(second)
precondition(!checkpointQueue.checkpoint(trackId: "local:one", position: 66000, playing: true))
precondition(checkpointQueue.position == 0, "切歌后旧音源回调不能污染新歌断点")
print("PASS: 原生断点身份校验、非法位置拒绝与冷启动恢复")

queue.collection = ["artist": "周杰伦", "cursors": [["source": "netease", "offset": 50, "done": false]], "seen": ["晴天"]]
queue.repeatMode = "list"; queue.shuffleMode = "off"
let oldPosition = queue.position
queue.append([first, second, ["source": "qqmusic", "id": "three", "title": "第三首"]])
precondition(queue.tracks.count == 3, "追加分页不能重复加入已有歌曲")
precondition(queue.currentKey == "netease:two" && queue.position == oldPosition, "补页不能重播当前歌曲")
let collectionRestored = SiriQueue()
collectionRestored.restore(queue.json)
precondition(collectionRestored.collection?["artist"] as? String == "周杰伦")
precondition(collectionRestored.repeatMode == "list" && collectionRestored.shuffleMode == "off")
print("PASS: 歌手曲库分页追加、去重、播放位置和冷启动游标恢复")

let selection = SiriSelection()
let selectedSong: [String: Any] = ["id": "xiaoban", "source": "netease", "title": "小半"]
selection.replace([selectedSong])
let stored = try JSONSerialization.data(withJSONObject: selection.tracks)
let newHandlerSelection = SiriSelection()
newHandlerSelection.replace(try JSONSerialization.jsonObject(with: stored) as! [[String: Any]])
let selectedCommand = try newHandlerSelection.command(identifier: "netease:xiaoban",
  hasMediaItems: true, query: "", artist: "", queue: [first])
precondition(selectedCommand["action"] as? String == "playTrack")
precondition(SiriQueue.key(selectedCommand["track"] as! [String: Any]) == "netease:xiaoban",
  "重建处理器后必须播放 Siri 所选小半，不能恢复旧队列")
let invalidIdentifiers: [String?] = ["netease:expired", nil, ""]
for identifier in invalidIdentifiers {
  do {
    _ = try newHandlerSelection.command(identifier: identifier, hasMediaItems: true,
      query: "", artist: "", queue: [first])
    preconditionFailure("选歌失效不能退回继续播放")
  } catch is SiriFailure {}
}
let resume = try newHandlerSelection.command(identifier: nil, hasMediaItems: false,
  query: "", artist: "", queue: [first])
precondition(resume["action"] as? String == "resume")
let queryCommand = try newHandlerSelection.command(identifier: nil, hasMediaItems: false,
  query: "小半", artist: "", queue: [first])
precondition(queryCommand["action"] as? String == "playQuery")
selection.replace(Array(repeating: selectedSong, count: 100))
precondition(selection.tracks.count == 50)
print("PASS: Siri 选歌跨回调与冷启动、过期选歌拒绝、搜索和继续播放分流、候选缓存上限")
