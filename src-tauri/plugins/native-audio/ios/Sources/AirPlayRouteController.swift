import AVKit
import UIKit
import WebKit

struct AirPlayRouteRequest: Decodable {
  let id: String
  let show: Bool
  let remove: Bool?
  let x: Double?
  let y: Double?
  let width: Double?
  let height: Double?
  let viewportWidth: Double?
  let viewportHeight: Double?
  let label: String?
  let tint: [Double]?
}

/// 原生按钮直接接收触摸；系统面板关闭前保留其呈现锚点。
final class AirPlayRouteController: NSObject, AVRoutePickerViewDelegate {
  private final class Entry {
    let picker = AVRoutePickerView(frame: .zero)
    var presenting = false
    var refreshAfterDismissal = false
    var removeAfterDismissal = false
    var shown = false
    var request: AirPlayRouteRequest?
    weak var webview: WKWebView?
  }
  private var entries: [String: Entry] = [:]
  private var visible = true
  var willPresent: (() -> Void)?
  var didDismiss: (() -> Void)?

  /// 音频会话激活后重建提前创建的控件，已呈现的弹窗保持到用户关闭。
  func refreshForPlayback() {
    for (id, entry) in Array(entries) {
      if entry.presenting {
        entry.refreshAfterDismissal = true
        continue
      }
      entry.picker.removeFromSuperview()
      entries.removeValue(forKey: id)
      if entry.shown, let request = entry.request, let webview = entry.webview {
        do { try update(request, in: webview) }
        catch { NSLog("[SPlayer AirPlay] 刷新路由控件失败: %@", error.localizedDescription) }
      }
    }
  }

  @discardableResult
  func update(_ request: AirPlayRouteRequest, in webview: WKWebView) throws -> Bool {
    if request.remove == true {
      if let entry = entries[request.id] {
        if entry.presenting { entry.removeAfterDismissal = true }
        else {
          entry.picker.removeFromSuperview()
          entries.removeValue(forKey: request.id)
        }
      }
      return false
    }
    guard request.show else {
      if let entry = entries[request.id] {
        entry.shown = false
        if !entry.presenting { entry.picker.isHidden = true }
      }
      return false
    }
    guard let x = request.x, let y = request.y,
          let width = request.width, let height = request.height,
          let viewportWidth = request.viewportWidth, let viewportHeight = request.viewportHeight,
          [x, y, width, height, viewportWidth, viewportHeight].allSatisfy({ $0.isFinite }),
          width > 0, height > 0, viewportWidth > 0, viewportHeight > 0 else {
      throw NSError(domain: "SPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "隔空播放按钮位置无效"])
    }
    var responder: UIResponder? = webview
    while responder != nil && !(responder is UIViewController) { responder = responder?.next }
    guard let owner = responder as? UIViewController, let host = owner.viewIfLoaded,
          let window = webview.window, host.window === window else {
      throw NSError(domain: "SPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "播放器尚未显示"])
    }
    let entry: Entry
    if let existing = entries[request.id] { entry = existing }
    else {
      entry = Entry()
      entry.picker.delegate = self
      entry.picker.prioritizesVideoDevices = false
      entry.picker.accessibilityIdentifier = "splayer-airplay-\(request.id)"
      entries[request.id] = entry
    }
    entry.shown = true
    entry.request = request
    entry.webview = webview
    // 系统弹窗可能使 WebView 暂时隐藏或改变布局，此时不能移动、隐藏或移除呈现者。
    guard !entry.presenting else { return true }
    let scaleX = webview.bounds.width / CGFloat(viewportWidth)
    let scaleY = webview.bounds.height / CGFloat(viewportHeight)
    entry.picker.frame = webview.convert(CGRect(x: CGFloat(x) * scaleX, y: CGFloat(y) * scaleY,
      width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY), to: host)
    entry.picker.accessibilityLabel = request.label
    if let tint = request.tint, tint.count == 4, tint.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
      entry.picker.tintColor = UIColor(red: CGFloat(tint[0]), green: CGFloat(tint[1]),
        blue: CGFloat(tint[2]), alpha: CGFloat(tint[3]))
    }
    entry.picker.activeTintColor = .systemBlue
    entry.picker.isHidden = !visible
    if entry.picker.superview !== host { host.addSubview(entry.picker) }
    return visible
  }

  func setVisible(_ value: Bool) {
    visible = value
    for entry in entries.values where !entry.presenting {
      entry.picker.isHidden = !value || !entry.shown
    }
  }

  func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    guard let entry = entries.values.first(where: { $0.picker === routePickerView }) else { return }
    entry.presenting = true
    willPresent?()
  }

  func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    guard let (id, entry) = entries.first(where: { $0.value.picker === routePickerView }) else { return }
    entry.presenting = false
    if entry.removeAfterDismissal || entry.refreshAfterDismissal {
      entry.picker.removeFromSuperview()
      entries.removeValue(forKey: id)
      if !entry.removeAfterDismissal, entry.shown,
         let request = entry.request, let webview = entry.webview {
        do { try update(request, in: webview) }
        catch { NSLog("[SPlayer AirPlay] 刷新路由控件失败: %@", error.localizedDescription) }
      }
    } else {
      entry.picker.isHidden = !visible || !entry.shown
      if entry.shown, let request = entry.request, let webview = entry.webview {
        do { try update(request, in: webview) }
        catch { entry.picker.isHidden = true }
      }
    }
    didDismiss?()
  }
}
