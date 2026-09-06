import UIKit

/// 零尺寸观察视图只接收系统外观变化，不覆盖窗口或网页的主题。
final class SystemAppearanceView: UIView {
  var changed: ((Bool) -> Void)?

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      changed?(traitCollection.userInterfaceStyle == .dark)
    }
  }
}
