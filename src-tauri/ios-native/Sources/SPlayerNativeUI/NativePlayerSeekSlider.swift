import SwiftUI

#if os(iOS)
  import UIKit

  /// 使用 UIKit 滑块保留触摸和辅助功能，轨道外观采用原版细线而非系统粗胶囊
  @MainActor
  struct NativePlayerSeekSlider: UIViewRepresentable {
    @ObservedObject var player: NativePlayerStore
    /// 将播放器绑定到控件事件，拖动过程中不回写旧进度
    func makeCoordinator() -> Coordinator { Coordinator(player: player) }
    /// 空闲隐藏滑块，触摸时显示圆点，命中区域仍保持 32pt 高
    func makeUIView(context: Context) -> UISlider {
      let slider = ThinSlider()
      slider.minimumValue = 0
      slider.isContinuous = false
      slider.minimumTrackTintColor = .white.withAlphaComponent(0.8)
      slider.maximumTrackTintColor = .white.withAlphaComponent(0.22)
      slider.accessibilityLabel = "播放进度"
      let clear = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { _ in }
      let thumb = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { _ in
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 12, height: 12)).fill()
      }
      slider.setThumbImage(clear, for: .normal)
      slider.setThumbImage(thumb, for: .highlighted)
      slider.addTarget(
        context.coordinator, action: #selector(Coordinator.seek(_:)),
        for: .valueChanged)
      return slider
    }
    /// 播放时同步当前时间，正在拖动时只保留用户输入
    func updateUIView(_ slider: UISlider, context: Context) {
      context.coordinator.player = player
      slider.maximumValue = Float(max(1, player.durationMs))
      slider.isEnabled = player.current != nil
      if !slider.isTracking { slider.value = Float(player.positionMs) }
    }
    @MainActor
    final class Coordinator: NSObject {
      var player: NativePlayerStore
      /// 保存唯一播放器，不创建额外播放实例
      init(player: NativePlayerStore) { self.player = player }
      /// 触摸结束后执行一次跳转
      @objc func seek(_ slider: UISlider) { player.seek(to: Double(slider.value)) }
    }
    private final class ThinSlider: UISlider {
      /// 原版支持点击轨道跳转，不要求命中隐藏的滑块
      override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isHighlighted = true
        updatePosition(touch)
        return true
      }
      /// 由同一条轨道坐标计算拖动值，保留完整触摸区域
      override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updatePosition(touch)
        return true
      }
      /// 松手才向播放器提交最终毫秒值
      override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { updatePosition(touch) }
        isHighlighted = false
        sendActions(for: .valueChanged)
      }
      /// 中断拖动时恢复空闲外观，不执行额外跳转
      override func cancelTracking(with event: UIEvent?) { isHighlighted = false }
      /// 将触点位置限制到轨道范围
      private func updatePosition(_ touch: UITouch) {
        let progress = min(1, max(0, (touch.location(in: self).x - 14) / max(1, bounds.width - 28)))
        value = minimumValue + Float(progress) * (maximumValue - minimumValue)
      }
      /// 仅改变轨道厚度，不缩小系统控件的交互高度
      override func trackRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.midY - 1.5, width: bounds.width, height: 3)
      }
    }
  }
#else
  struct NativePlayerSeekSlider: View {
    @ObservedObject var player: NativePlayerStore
    var body: some View { NativeSeekSlider(player: player) }
  }
#endif
