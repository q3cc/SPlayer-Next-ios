import Foundation

let url = URL(string: CommandLine.arguments[1])!
let size = Int64(CommandLine.arguments[2])!
let digest = CommandLine.arguments[3]
let absoluteDirectory = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
// 使用带基址的 URL，覆盖目录枚举与下载目录表示不同但实际路径相同的情况。
let directory = URL(fileURLWithPath: absoluteDirectory.lastPathComponent, isDirectory: true,
  relativeTo: absoluteDirectory.deletingLastPathComponent())
let done = DispatchSemaphore(value: 0)
var success = false
let task = IpaDownload(url: url, size: size, digest: digest, directory: directory,
  progress: { received, total, speed in
    print("progress \(received) \(total) \(speed)")
  }, completion: { result in
    switch result {
    case .success(let file): print("saved \(file.path)"); success = true
    case .failure(let error): print("error \(error.localizedDescription)")
    }
    done.signal()
  })
task.start()
guard done.wait(timeout: .now() + 30) == .success else { exit(2) }
exit(success ? 0 : 1)
