import Foundation

/** 直接写标准错误以复用诊断文件重定向，避免 stdout 缓冲丢失卡住前的最后一步。 */
final class FolderPickerTrace {
  private let id: String
  private let started = ProcessInfo.processInfo.systemUptime

  init(id: String) {
    self.id = id
  }

  func log(_ stage: String, _ detail: String = "") {
    let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
    let line = "[folder-trace] id=\(id) layer=swift stage=\(stage) elapsedMs=\(elapsed) main=\(Thread.isMainThread) \(detail)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}
