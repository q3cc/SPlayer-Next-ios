import SwiftUI

struct NativeLogo: View {
  /// 按原版 SLogo 的 1024 坐标重建矢量标志，避免大封面放大低分辨率 PNG
  var body: some View {
    GeometryReader { geometry in
      let scale = min(geometry.size.width, geometry.size.height) / 1024
      ZStack {
        Path { path in
          path.addEllipse(in: CGRect(x: 65.618, y: 131.708, width: 892.292, height: 892.292))
          path.addEllipse(in: CGRect(x: 439.935, y: 508.701, width: 143.659, height: 143.659))
        }.fill(Color.primary.opacity(0.30), style: FillStyle(eoFill: true))
        Path { path in
          path.move(to: CGPoint(x: 802.205, y: 0.541))
          path.addLine(to: CGPoint(x: 634.008, y: 37.571))
          path.addCurve(
            to: CGPoint(x: 580.917, y: 103.601), control1: CGPoint(x: 602, y: 44),
            control2: CGPoint(x: 580.917, y: 71))
          path.addLine(to: CGPoint(x: 580.917, y: 223.614))
          path.addLine(to: CGPoint(x: 584.486, y: 573.393))
          path.addLine(to: CGPoint(x: 698.699, y: 573.393))
          path.addLine(to: CGPoint(x: 698.699, y: 223.614))
          path.addLine(to: CGPoint(x: 807.559, y: 223.614))
          path.addQuadCurve(
            to: CGPoint(x: 834.328, y: 197.292), control: CGPoint(x: 834.328, y: 223.614))
          path.addLine(to: CGPoint(x: 834.328, y: 26.864))
          path.addCurve(
            to: CGPoint(x: 802.205, y: 0.541), control1: CGPoint(x: 834.328, y: 9),
            control2: CGPoint(x: 820, y: -3))
          path.closeSubpath()
        }.fill(Color.primary)
        Path { path in
          path.addEllipse(in: CGRect(x: 324.829, y: 386.457, width: 373.870, height: 373.870))
          path.addEllipse(in: CGRect(x: 440.381, y: 508.255, width: 142.767, height: 142.767))
        }.fill(Color.primary, style: FillStyle(eoFill: true))
      }.frame(width: 1024, height: 1024).scaleEffect(scale, anchor: .topLeading)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }.accessibilityLabel("SPlayer 标志")
  }
}
