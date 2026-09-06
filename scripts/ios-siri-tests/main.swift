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
