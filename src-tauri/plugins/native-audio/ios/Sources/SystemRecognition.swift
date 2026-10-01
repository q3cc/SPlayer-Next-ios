import Foundation
import ReplayKit
import UIKit
import Tauri

private final class BroadcastPickerController: UIViewController {
  var cancelled: (() -> Void)?

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
  private var pending: Invoke?
  private var timer: Timer?
  private var session: String?
  private var expires = Date.distantPast
  private weak var picker: BroadcastPickerController?
  private let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.top.imsyy.splayer-next.ios.recognition")

  func start(_ invoke: Invoke, presenter: UIViewController?) {
    cancel()
    guard let directory = directory, let presenter = presenter else {
      invoke.reject("无法启动屏幕广播，请检查 App Groups 签名权限")
      return
    }
    let id = UUID().uuidString
    expires = Date().addingTimeInterval(90)
    do {
      // 仅清理本功能专用 App Group 中上次未完成的临时采样。
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
        pending?.resolve(["pcm": pcm])
        cleanup()
        return
      }
      if result["status"] as? String == "error" {
        pending?.reject(result["message"] as? String ?? "屏幕广播采集失败")
        cleanup()
        return
      }
      if result["status"] as? String == "capturing" { picker?.dismiss(animated: true) }
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
    if let directory = directory {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("request.json"))
      if let session = session { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(session).json")) }
    }
    session = nil
  }
}

extension NativeAudioPlugin {
  @objc func recognitionStart(_ invoke: Invoke) {
    DispatchQueue.main.async {
      guard var presenter = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .filter({ $0.activationState == .foregroundActive })
        .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
        invoke.reject("播放器尚未显示")
        return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      self.systemRecognition.start(invoke, presenter: presenter)
    }
  }

  @objc func recognitionCancel(_ invoke: Invoke) {
    DispatchQueue.main.async {
      self.systemRecognition.cancel()
      invoke.resolve()
    }
  }
}
