import Foundation
import ReplayKit
import UIKit
import Tauri
import WebKit

private final class BroadcastPickerController: UIViewController {
  var cancelled: (() -> Void)?
  private var broadcastPicker: RPSystemBroadcastPickerView?
  private var opened = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !opened else { return }
    opened = true
    // 转发用户的开始操作到系统按钮；是否广播仍由系统确认窗口决定。
    broadcastPicker?.subviews.compactMap { $0 as? UIButton }.first?
      .sendActions(for: .touchUpInside)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let label = UILabel()
    label.text = "点击下方按钮，选择 SPlayer 并开始广播。然后切换到播放音乐的 App，采集完成后返回查看结果。只识别声音，不保存画面。"
    label.numberOfLines = 0
    label.textAlignment = .center
    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
    picker.preferredExtension = "top.imsyy.splayer-next.ios.RecognitionBroadcast"
    picker.showsMicrophoneButton = false
    broadcastPicker = picker
    let close = UIButton(type: .system)
    close.setTitle("取消识别", for: .normal)
    close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, picker, close])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 24
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      picker.widthAnchor.constraint(equalToConstant: 60),
      picker.heightAnchor.constraint(equalToConstant: 60),
    ])
  }

  @objc private func cancel() { cancelled?() }
}

final class SystemRecognition {
  weak var webView: WKWebView?
  var didStartCapture: (() -> Void)?
  private var startedCapture = false
  private var pending: Invoke?
  private var timer: Timer?
  private var session: String?
  private var expires = Date.distantPast
  private weak var picker: BroadcastPickerController?
  private var directory: URL?

  func start(_ invoke: Invoke) {
    cancel()
    // 使用实际承载播放器的窗口，避免 iPad 浮层或系统窗口抢占 keyWindow。
    guard var presenter = webView?.window?.rootViewController else {
      invoke.reject("播放器窗口尚未就绪，请返回播放器重试")
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let id = UUID().uuidString
    expires = Date().addingTimeInterval(90)
    do {
      let directory = try RecognitionStorage.directory()
      self.directory = directory
      // 共享组可能由重签名证书的多个应用共用，只清理本应用子目录。
      for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "json" {
        try FileManager.default.removeItem(at: file)
      }
      let data = try JSONSerialization.data(withJSONObject: ["id": id, "expires": expires.timeIntervalSince1970])
      try data.write(to: directory.appendingPathComponent("request.json"), options: .atomic)
    } catch { invoke.reject(error.localizedDescription); return }
    session = id
    pending = invoke
    let controller = BroadcastPickerController()
    controller.isModalInPresentation = true
    controller.modalPresentationStyle = .pageSheet
    controller.cancelled = { [weak self] in self?.cancel() }
    picker = controller
    presenter.present(controller, animated: true)
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func cancel() {
    pending?.reject("识别已取消")
    cleanup()
  }

  private func poll() {
    guard let directory = directory, let session = session else { return }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("\(session).json")),
       let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if result["status"] as? String == "done", let pcm = result["pcm"] as? [Double] {
        do { try RecognitionCaptureExport.save(pcm, source: result["source"] as? [String: Any]) }
        catch {
          pending?.reject("采样已完成，但保存试听文件失败：\(error.localizedDescription)")
          cleanup()
          return
        }
        pending?.resolve(["pcm": pcm])
        cleanup()
        return
      }
      if result["status"] as? String == "error" {
        pending?.reject(result["message"] as? String ?? "屏幕广播采集失败")
        cleanup()
        return
      }
      if result["status"] as? String == "capturing", !startedCapture {
        startedCapture = true
        didStartCapture?()
        picker?.dismiss(animated: true)
      }
    }
    if Date() >= expires {
      pending?.reject("屏幕广播等待超时，请重新识别")
      cleanup()
    }
  }

  private func cleanup() {
    timer?.invalidate()
    timer = nil
    picker?.dismiss(animated: true)
    picker = nil
    pending = nil
    startedCapture = false
    if let directory = directory {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("request.json"))
      if let session = session { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(session).json")) }
    }
    session = nil
    directory = nil
  }
}

extension NativeAudioPlugin {
  @objc func recognitionStart(_ invoke: Invoke) {
    DispatchQueue.main.async {
      self.systemRecognition.didStartCapture = { [weak self] in
        self?.trigger("recognitionCaptureStarted", data: [:])
      }
      self.systemRecognition.start(invoke)
    }
  }

  @objc func recognitionCancel(_ invoke: Invoke) {
    DispatchQueue.main.async {
      self.systemRecognition.cancel()
      invoke.resolve()
    }
  }
}
