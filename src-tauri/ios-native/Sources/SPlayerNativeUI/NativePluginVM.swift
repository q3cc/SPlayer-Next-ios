import CQuickJS
import Foundation

/// 独立解释器线程；支持强制取消、执行时限和内存上限，不使用 WebView 或 JIT
final class NativePluginVM: @unchecked Sendable {
  private let queue = DispatchQueue(label: "splayer.native.plugin", qos: .userInitiated)
  private let lock = NSLock()
  private var engine: OpaquePointer?
  private var timer: DispatchSourceTimer?
  private var stopped = false
  var message: (@Sendable ([String: Any]) -> Void)?
  var failure: (@Sendable (String) -> Void)?

  /// 队列操作持有实例直到结束；最后一个引用释放后回收解释器和弱引用计时器
  deinit {
    timer?.cancel()
    if let engine {
      queue.async(execute: DispatchWorkItem { sp_js_destroy(engine) })
    }
  }

  /// 只从随包资源加载受信任的宿主兼容层
  func start() {
    queue.async { [self] in
      lock.lock()
      guard !stopped else {
        lock.unlock()
        return
      }
      engine = sp_js_create()
      lock.unlock()
      guard engine != nil else {
        fail("无法创建插件解释器")
        return
      }
      do {
        for name in ["native-plugin-bootstrap", "native-plugin"] {
          guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw SiriFailure("缺少原生插件运行时")
          }
          guard evaluate(try String(contentsOf: url, encoding: .utf8)) else { return }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in _ = self?.evaluate("__tick()") }
        self.timer = timer
        timer.resume()
        drain()
      } catch { fail(error.localizedDescription) }
    }
  }

  /// 解析源码头部，不执行第三方源码
  func inspect(_ source: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: [source]),
      let text = String(data: data, encoding: .utf8)
    else { return }
    queue.async { [weak self] in
      _ = self?.evaluate(
        "__nativeSend(JSON.stringify({kind:'manifest',data:__parsePlugin(\(text)[0])}))")
    }
  }

  /// 数据仅以 JSON 进入脚本，不拼接不可信 JavaScript 代码
  func send(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
      let json = String(data: data, encoding: .utf8),
      let quoted = try? JSONSerialization.data(withJSONObject: [json]),
      let string = String(data: quoted, encoding: .utf8)
    else { return }
    queue.async { [weak self] in _ = self?.evaluate("__deliver(\(string)[0])") }
  }

  /// 原子中断标志可在脚本死循环时设置，释放操作仍回到解释器线程
  func stop() {
    lock.lock()
    stopped = true
    if let engine { sp_js_cancel(engine) }
    lock.unlock()
    queue.async { [self] in destroy() }
  }

  /// 单轮计算限时，异步网络等待不占用计算预算
  @discardableResult private func evaluate(_ source: String) -> Bool {
    guard let engine else { return false }
    if sp_js_eval(engine, source, 2000) < 0 || sp_js_jobs(engine, 2000) < 0 {
      fail(String(cString: sp_js_error(engine)))
      return false
    }
    drain()
    return true
  }

  /// 解析消息后交由主线程宿主处理，不向脚本传入 Swift 对象
  private func drain() {
    guard let engine else { return }
    while let pointer = sp_js_take(engine) {
      let data = Data(String(cString: pointer).utf8)
      sp_js_free_string(pointer)
      if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        message?(value)
      }
    }
  }
  /// 通知宿主错误并停止该插件解释器
  private func fail(_ reason: String) {
    failure?(reason)
    destroy()
  }
  /// 在执行队列取消计时器并释放 C 运行时
  private func destroy() {
    timer?.cancel()
    timer = nil
    lock.lock()
    if let engine {
      sp_js_destroy(engine)
      self.engine = nil
    }
    stopped = true
    lock.unlock()
  }
}
