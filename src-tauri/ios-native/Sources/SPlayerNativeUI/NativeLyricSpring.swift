import Foundation

/// 参数逐项对应 src/types/settings.ts 的 SPRING_PRESETS
struct NativeLyricSpring: Identifiable {
  let id: String
  let name: String
  let mass: Double
  let damping: Double
  let stiffness: Double
  static let presets: [Self] = [
    .init(id: "default", name: "默认", mass: 0.9, damping: 15, stiffness: 90),
    .init(id: "smooth", name: "更平滑", mass: 1.2, damping: 22, stiffness: 80),
    .init(id: "responsive", name: "快速跟手", mass: 0.5, damping: 18, stiffness: 150),
    .init(id: "jello", name: "果冻感", mass: 0.6, damping: 8, stiffness: 120),
    .init(id: "heavy", name: "厚重缓慢", mass: 2, damping: 25, stiffness: 60),
    .init(id: "noBounce", name: "无弹跳", mass: 1, damping: 30, stiffness: 100),
  ]
}
