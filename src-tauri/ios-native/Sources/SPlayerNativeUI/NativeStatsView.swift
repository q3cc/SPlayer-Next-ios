import SwiftUI

/// 统计页：曲库概览、聆听足迹、播放时段、音频格式与最常听榜单，对应原版 pages/Stats.vue
@MainActor
struct NativeStatsView: View {
  @ObservedObject var player: NativePlayerStore
  @ObservedObject var stats: NativePlayStats
  let navigate: (NativePage) -> Void
  @State private var library: NativeLibraryStats?
  @State private var daily: [String: Int] = [:]
  @State private var hourly: [Int] = []
  @State private var songs: [NativeRankItem] = []
  @State private var albums: [NativeRankItem] = []
  @State private var artists: [NativeRankItem] = []
  @Environment(\.nativeViewport) private var width

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        overview(columns: width >= 1024 ? 5 : width >= 768 ? 3 : 2)
        if width >= 1280 {
          HStack(spacing: 20) {
            heatmap.frame(width: 300)
            hours
            formats.frame(width: 400)
          }
        } else {
          HStack(spacing: 20) {
            heatmap.frame(width: 300)
            hours
          }
          formats
        }
        let columns = width >= 1280 ? 3 : width >= 768 ? 2 : 1
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: columns),
          alignment: .leading, spacing: 20
        ) {
          NativeStatsTopList(
            title: "最常听的歌曲", icon: "music.note", circle: false, items: songs,
            subtitle: { $0.track.artist }
          ) { player.playNow($0.track) }
          NativeStatsTopList(
            title: "最常听的专辑", icon: "opticaldisc", circle: false, items: albums,
            subtitle: { $0.track.artist }
          ) { _ in navigate(.albums) }
          NativeStatsTopList(
            title: "最常听的歌手", icon: "person", circle: true, items: artists,
            subtitle: { _ in nil }
          ) { _ in navigate(.artists) }
        }
      }
      .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
      .frame(maxWidth: 1400).frame(maxWidth: .infinity)
    }
    .task(id: stats.revision) { refresh() }
    .task(id: player.tracks.count) {
      let tracks = player.tracks
      let sizes = await player.librarySizes()
      library = NativeStatsMath.library(tracks, sizes: sizes)
    }
  }

  /// 每次有新记录时重新汇总；记录量为每次播放一条，按需全量计算
  private func refresh() {
    let data = stats.data
    let calendar = Calendar.current
    daily = NativeStatsMath.daily(data, days: NativeStatsHeatmap.days, now: Date(), calendar: calendar)
    hourly = NativeStatsMath.hourly(data, calendar: calendar)
    songs = NativeStatsMath.topTracks(data, limit: 10)
    albums = NativeStatsMath.topAlbums(data, limit: 10)
    artists = NativeStatsMath.topArtists(data, limit: 10)
  }

  private func overview(columns: Int) -> some View {
    let duration = library.map { Int($0.totalDurationMs / 60000) }
    let size = library.map { Double($0.totalFileSize) / 1_048_576 }
    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: columns), spacing: 20
    ) {
      overviewCard("歌曲", icon: "music.note", value: library.map { "\($0.trackCount)" }) {
        navigate(.library)
      }
      overviewCard("专辑", icon: "opticaldisc", value: library.map { "\($0.albumCount)" }) {
        navigate(.albums)
      }
      overviewCard("歌手", icon: "person", value: library.map { "\($0.artistCount)" }) {
        navigate(.artists)
      }
      overviewCard(
        "总时长", icon: "clock", value: duration.map { "\($0 / 60)" }, unit: "h",
        value2: duration.map { "\($0 % 60)" }, unit2: "m")
      overviewCard(
        "总大小", icon: "internaldrive",
        value: size.map { String(format: "%.1f", $0 < 1024 ? $0 : $0 / 1024) },
        unit: size.map { $0 < 1024 ? "MB" : "GB" })
    }
  }

  /// 概览卡片：SCard 内边距 16×12，数字 30 bold 行高 1，右下角 72 衬底图标
  private func overviewCard(
    _ label: String, icon: String, value: String?, unit: String? = nil, value2: String? = nil,
    unit2: String? = nil, action: (() -> Void)? = nil
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12)
    return Button {
      action?()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
          Text(value ?? "--").font(.system(size: 30, weight: .bold).monospacedDigit())
            .foregroundStyle(Color.nativeOnSurface)
          if let unit, value != nil {
            Text(unit).font(.system(size: 14, weight: .medium))
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
          }
          if let value2 {
            Text(value2).font(.system(size: 30, weight: .bold).monospacedDigit())
              .foregroundStyle(Color.nativeOnSurface)
            if let unit2 {
              Text(unit2).font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
            }
          }
        }.frame(height: 30)
        Text(label).font(.system(size: 12)).lineLimit(1)
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16).padding(.vertical, 12)
      .background(alignment: .bottomTrailing) {
        Image(systemName: icon).font(.system(size: 60, weight: .light))
          .frame(width: 72, height: 72)
          .foregroundStyle(Color.nativePrimary.opacity(0.2))
          .rotationEffect(.degrees(-14)).offset(x: 8, y: 12)
      }
      .clipShape(shape)
      .nativeCard(radius: 12)
      .contentShape(shape)
    }.buttonStyle(.plain).allowsHitTesting(action != nil)
  }

  private var heatmap: some View {
    card(title: "聆听足迹", trailing: "近 90 天") { NativeStatsHeatmap(daily: daily) }
  }

  private var hours: some View {
    card(title: "播放时段", spacing: 8) { NativeStatsHours(hourly: hourly) }
  }

  private var formats: some View {
    card(
      title: "音频格式",
      trailing: library.map { "\(NativeStatsFormats.chartCodecs($0).count) 种格式" } ?? "--"
    ) { NativeStatsFormats(library: library) }
  }

  /// 统计卡片外框：SCard 圆角 12、内边距 16×12，高度与原版 h-52 一致
  private func card<Content: View>(
    title: String, trailing: String? = nil, spacing: CGFloat = 12,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: spacing) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(title).font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color.nativeOnSurface)
        Spacer(minLength: 0)
        if let trailing {
          Text(trailing).font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.45))
        }
      }
      content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .frame(height: 208).frame(maxWidth: .infinity)
    .nativeCard(radius: 12)
  }
}

/// 近 90 天热力图：按周成列，周日为首行，颜色深浅按当日峰值比例
struct NativeStatsHeatmap: View {
  static let days = 90
  let daily: [String: Int]
  private let cell: CGFloat = 13

  var body: some View {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let start = calendar.date(byAdding: .day, value: -(Self.days - 1), to: today) ?? today
    let lead = calendar.component(.weekday, from: start) - 1
    let weeks = Int((Double(lead + Self.days) / 7).rounded(.up))
    let peak = daily.values.max() ?? 0
    let months = monthLabels(start: start, lead: lead, weeks: weeks, calendar: calendar)
    let label = Color.nativeOnSurfaceVariant.opacity(0.5)
    VStack(spacing: 12) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .trailing, spacing: 2) {
          Color.clear.frame(width: 1, height: 20)
          ForEach(0..<7, id: \.self) { dow in
            Text([1, 3, 5].contains(dow) ? ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][dow] : "")
              .font(.system(size: 12)).foregroundStyle(label).frame(height: cell)
          }
        }
        HStack(alignment: .top, spacing: 2) {
          ForEach(0..<weeks, id: \.self) { week in
            VStack(spacing: 2) {
              Text(months[week] ?? "").font(.system(size: 12)).foregroundStyle(label)
                .fixedSize().frame(width: cell, height: 20, alignment: .top)
              ForEach(0..<7, id: \.self) { dow in
                let index = week * 7 + dow - lead
                if index >= 0 && index < Self.days,
                  let date = calendar.date(byAdding: .day, value: index, to: start)
                {
                  RoundedRectangle(cornerRadius: 3)
                    .fill(Self.color(daily[NativeStatsMath.dayKey(date, calendar: calendar)] ?? 0, peak: peak))
                    .frame(width: cell, height: cell)
                } else {
                  Color.clear.frame(width: cell, height: cell)
                }
              }
            }
          }
        }
      }.frame(maxHeight: .infinity)
      HStack(spacing: 8) {
        Text("少")
        ForEach(1...5, id: \.self) { level in
          RoundedRectangle(cornerRadius: 3)
            .fill(Self.color(Int((Double(level) / 5 * Double(peak)).rounded()), peak: peak))
            .frame(width: 12, height: 12)
        }
        Text("多")
      }.font(.system(size: 12)).foregroundStyle(label)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("近 90 天共播放 \(daily.values.reduce(0, +)) 次")
  }

  /// 月份变化处的列显示月份；与上一个标签相距不足三列时省略，避免文字重叠
  private func monthLabels(start: Date, lead: Int, weeks: Int, calendar: Calendar) -> [Int: String] {
    var labels: [Int: String] = [:]
    var previous: Int?
    var shown = -3
    for week in 0..<weeks {
      let first = max(0, week * 7 - lead)
      guard first < Self.days, let date = calendar.date(byAdding: .day, value: first, to: start)
      else { continue }
      let month = calendar.component(.month, from: date)
      if month != previous && week - shown >= 3 {
        labels[week] = "\(month)月"
        shown = week
      }
      previous = month
    }
    return labels
  }

  /// 无播放为 primary/6 底色，其余按峰值比例 14%–86%
  static func color(_ count: Int, peak: Int) -> Color {
    guard count > 0, peak > 0 else { return Color.nativePrimary.opacity(0.06) }
    return Color.nativePrimary.opacity(0.14 + Double(count) / Double(peak) * 0.72)
  }
}

/// 播放时段折线：按原版 240×128 坐标系与 Catmull-Rom 平滑绘制，最高点标出“最常播放”
struct NativeStatsHours: View {
  let hourly: [Int]

  var body: some View {
    let total = hourly.reduce(0, +)
    let peak = hourly.indices.max { hourly[$0] < hourly[$1] }
    let points = Self.points(hourly)
    VStack(spacing: 8) {
      GeometryReader { geometry in
        let sx = geometry.size.width / 240
        let sy = geometry.size.height / 128
        let scale = CGAffineTransform(scaleX: sx, y: sy)
        let line = Self.line(points)
        ZStack(alignment: .topLeading) {
          if total > 0 {
            Self.area(line).applying(scale).fill(Color.nativePrimary.opacity(0.08))
            line.applying(scale).stroke(
              Color.nativePrimary,
              style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let peak {
              let point = points[peak]
              Circle().fill(Color.nativePrimary).frame(width: 8, height: 8)
                .padding(2).background(Color.nativeSurfacePanel, in: Circle())
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .position(x: point.x * sx, y: point.y * sy)
              VStack(spacing: 4) {
                Text("最常播放").font(.system(size: 9, weight: .medium)).frame(height: 9)
                  .foregroundStyle(Color.nativeOnPrimary.opacity(0.8))
                Text(String(format: "%02d:00", peak)).font(.system(size: 12, weight: .bold).monospacedDigit())
                  .frame(height: 12).foregroundStyle(Color.nativeOnPrimary)
              }
              .fixedSize().padding(.horizontal, 8).padding(.vertical, 4)
              .background(Color.nativePrimary, in: RoundedRectangle(cornerRadius: 6))
              .shadow(color: .black.opacity(0.1), radius: 3, y: 3)
              .position(
                x: min(212, max(28, point.x)) * sx, y: max(20, point.y - 20) * sy)
            }
          } else {
            Text("暂无播放时段数据").font(.system(size: 14))
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }.frame(maxHeight: .infinity)
      HStack {
        ForEach(["00", "06", "12", "18", "24"], id: \.self) { label in
          Text(label)
          if label != "24" { Spacer() }
        }
      }.font(.system(size: 10).monospacedDigit())
        .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4))
      if total > 0, let peak {
        Text("你最喜欢在 \(String(format: "%02d", peak)):00 听歌，共计 \(hourly[peak]) 首")
          .font(.system(size: 12)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.55))
          .frame(maxWidth: .infinity)
      }
    }
  }

  /// 24 个时段在原版 240×128 视框内的坐标，峰值顶到 y=16，零值落在 y=120
  private static func points(_ hourly: [Int]) -> [CGPoint] {
    let peak = hourly.max() ?? 0
    return (0..<24).map { hour in
      let count = hour < hourly.count ? hourly[hour] : 0
      let ratio = peak > 0 ? Double(count) / Double(peak) : 0
      return CGPoint(x: Double(hour) / 23 * 240, y: 120 - ratio * 104)
    }
  }

  /// 控制点纵坐标夹在 8–120 之间，避免曲线越过顶部或沉到基线以下
  private static func line(_ points: [CGPoint]) -> Path {
    Path { path in
      guard let first = points.first else { return }
      path.move(to: first)
      for index in 0..<(points.count - 1) {
        let p0 = points[max(0, index - 1)]
        let p1 = points[index]
        let p2 = points[index + 1]
        let p3 = points[min(points.count - 1, index + 2)]
        path.addCurve(
          to: p2,
          control1: CGPoint(
            x: p1.x + (p2.x - p0.x) / 6, y: min(120, max(8, p1.y + (p2.y - p0.y) / 6))),
          control2: CGPoint(
            x: p2.x - (p3.x - p1.x) / 6, y: min(120, max(8, p2.y - (p3.y - p1.y) / 6))))
      }
    }
  }

  private static func area(_ line: Path) -> Path {
    var path = line
    path.addLine(to: CGPoint(x: 240, y: 124))
    path.addLine(to: CGPoint(x: 0, y: 124))
    path.closeSubpath()
    return path
  }
}

/// 音频格式圆环：最多四种格式，中间显示无损占比
struct NativeStatsFormats: View {
  let library: NativeLibraryStats?

  /// 参与圆环的格式：去掉空编码后取前四种
  static func chartCodecs(_ library: NativeLibraryStats) -> [(codec: String, count: Int)] {
    Array(
      library.codecs.filter { !$0.codec.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(4))
  }

  var body: some View {
    let codecs = library.map(Self.chartCodecs) ?? []
    let total = codecs.reduce(0) { $0 + $1.count }
    if library != nil, !codecs.isEmpty, total > 0 {
      let lossless = codecs.filter { NativeStatsMath.losslessCodecs.contains($0.codec) }
        .reduce(0) { $0 + $1.count }
      let percents = codecs.map { Double($0.count) / Double(total) * 100 }
      let segments = NativeStatsDonutSegment.layout(percents)
      HStack(spacing: 16) {
        ZStack {
          ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
            segment.fill(Color.nativePrimary.opacity(Self.opacity(index)))
          }.rotationEffect(.degrees(-90))
          VStack(spacing: 4) {
            Text("无损占比").font(.system(size: 10))
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.55))
            Text(String(format: "%.1f%%", Double(lossless) / Double(total) * 100))
              .font(.system(size: 20, weight: .bold).monospacedDigit()).frame(height: 20)
              .foregroundStyle(Color.nativeOnSurface)
          }
        }.frame(width: 128, height: 128)
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12
        ) {
          ForEach(Array(codecs.enumerated()), id: \.offset) { index, item in
            HStack(spacing: 8) {
              Circle().fill(Color.nativePrimary.opacity(Self.opacity(index)))
                .frame(width: 8, height: 8)
              VStack(alignment: .leading, spacing: 0) {
                Text(item.codec.uppercased()).font(.system(size: 12, weight: .medium))
                  .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
                Text("\(item.count) 首 · \(String(format: "%.1f%%", percents[index]))")
                  .font(.system(size: 10).monospacedDigit())
                  .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5)).lineLimit(1)
              }
              Spacer(minLength: 0)
            }
          }
        }
      }.frame(maxWidth: 520)
    } else if library == nil {
      ProgressView().tint(Color.nativePrimary.opacity(0.6))
    } else {
      VStack(spacing: 8) {
        Image(systemName: "music.note").font(.system(size: 24)).frame(width: 28, height: 28)
        Text("暂无数据，去听一些歌吧").font(.system(size: 14))
      }.foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4))
    }
  }

  static func opacity(_ index: Int) -> Double { max(0.24, 0.92 - Double(index) * 0.14) }
}

/// 圆环扇区：原版 StatsDonutChart 的 128 视框、半径 46、环宽 16、段间 2、圆角 2.5
private struct NativeStatsDonutSegment: Shape {
  let offset: Double
  let percent: Double

  /// 小于 2.5% 的分段放大到 2.5%，其余等比例压缩，保证每段可见
  static func layout(_ percents: [Double]) -> [Self] {
    let minimum = 2.5
    let small = percents.filter { $0 < minimum }.count
    let flexible = percents.filter { $0 >= minimum }.reduce(0, +)
    let scale = flexible > 0 ? (100 - Double(small) * minimum) / flexible : 1
    var offset = 0.0
    return percents.map { percent in
      let visual = percent < minimum ? minimum : percent * scale
      defer { offset += visual }
      return Self(offset: offset, percent: visual)
    }
  }

  func path(in rect: CGRect) -> Path {
    let outer = 54.0
    let inner = 38.0
    let gap = 2.0 / 46
    let start = offset / 100 * .pi * 2 + gap / 2
    let end = (offset + percent) / 100 * .pi * 2 - gap / 2
    let corner = min(2.5, (end - start) * inner * 0.45, 8)
    let outerCorner = corner / outer
    let innerCorner = corner / inner
    let point = { (radius: Double, angle: Double) in
      CGPoint(x: 64 + radius * cos(angle), y: 64 + radius * sin(angle))
    }
    var path = Path()
    path.move(to: point(outer, start + outerCorner))
    path.addArc(
      center: CGPoint(x: 64, y: 64), radius: outer, startAngle: .radians(start + outerCorner),
      endAngle: .radians(end - outerCorner), clockwise: false)
    path.addQuadCurve(to: point(outer - corner, end), control: point(outer, end))
    path.addLine(to: point(inner + corner, end))
    path.addQuadCurve(to: point(inner, end - innerCorner), control: point(inner, end))
    path.addArc(
      center: CGPoint(x: 64, y: 64), radius: inner, startAngle: .radians(end - innerCorner),
      endAngle: .radians(start + innerCorner), clockwise: true)
    path.addQuadCurve(to: point(inner + corner, start), control: point(inner, start))
    path.addLine(to: point(outer - corner, start))
    path.addQuadCurve(to: point(outer, start + outerCorner), control: point(outer, start))
    path.closeSubpath()
    return path.applying(CGAffineTransform(scaleX: rect.width / 128, y: rect.height / 128))
  }
}

/// 最常听榜单卡片：第一名大图展示，其余按序列出
struct NativeStatsTopList: View {
  let title: String
  let icon: String
  let circle: Bool
  let items: [NativeRankItem]
  let subtitle: (NativeRankItem) -> String?
  let open: (NativeRankItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Color.nativePrimary)
          .frame(width: 40, height: 40)
          .background(Color.nativePrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 0) {
          Text(title).font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
          Text("TOP \(items.count)").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.45))
        }
      }.padding(12)
      Group {
        if let first = items.first {
          VStack(spacing: 8) {
            Button {
              open(first)
            } label: {
              leader(first)
            }.buttonStyle(NativeStatsLeaderStyle())
            VStack(spacing: 0) {
              ForEach(Array(items.dropFirst().enumerated()), id: \.element.id) { index, item in
                Button {
                  open(item)
                } label: {
                  row(item, rank: index + 2)
                }.buttonStyle(NativePressStyle(radius: 12, amount: 0.06))
              }
            }
          }
        } else {
          VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).frame(width: 28, height: 28)
            Text("暂无播放数据").font(.system(size: 14))
          }.foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4))
            .frame(maxWidth: .infinity, minHeight: 224)
            .background(Color.nativeOnSurface.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
        }
      }.padding(.horizontal, 12).padding(.bottom, 12)
    }.nativeCard(radius: 12)
  }

  /// 第一名：80 封面 + 标题、副标题与 30 bold 播放次数，右上角 TOP 1
  private func leader(_ item: NativeRankItem) -> some View {
    HStack(spacing: 12) {
      cover(item, size: 80)
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
          if let text = subtitle(item) {
            Text(text).font(.system(size: 12)).frame(height: 12)
              .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6)).lineLimit(1)
          }
        }.padding(.trailing, 48)
        Spacer(minLength: 0)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(Self.count(item.plays)).font(.system(size: 30, weight: .bold).monospacedDigit())
            .foregroundStyle(Color.nativeOnSurface)
          Text("次播放").font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.55))
        }.frame(height: 30)
      }
      .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).frame(height: 80)
      .overlay(alignment: .topTrailing) {
        Text("TOP 1").font(.system(size: 12, weight: .bold)).tracking(0.6)
          .foregroundStyle(Color.nativePrimary).padding(.top, 4)
      }
    }
    .padding(12).contentShape(RoundedRectangle(cornerRadius: 16))
  }

  /// 其余名次：序号 20、封面 44、标题与副标题、20 bold 播放次数
  private func row(_ item: NativeRankItem, rank: Int) -> some View {
    HStack(spacing: 8) {
      Text(String(format: "%02d", rank)).font(.system(size: 12, weight: .bold).monospacedDigit())
        .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.45)).frame(width: 20)
      cover(item, size: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
        if let text = subtitle(item) {
          Text(text).font(.system(size: 12))
            .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.5)).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 0) {
        Text(Self.count(item.plays)).font(.system(size: 20, weight: .bold).monospacedDigit())
          .foregroundStyle(Color.nativeOnSurface).frame(height: 20)
        Text("次播放").font(.system(size: 10))
          .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.45))
      }.padding(.leading, 8)
    }.padding(6).frame(minHeight: 56).contentShape(Rectangle())
  }

  /// 封面带 1px 内描边，浅色 black/10、深色 white/10
  private func cover(_ item: NativeRankItem, size: CGFloat) -> some View {
    let radius: CGFloat = circle ? size / 2 : size > 50 ? 12 : 8
    return NativeArtwork(cover: item.track.cover, radius: radius)
      .frame(width: size, height: size)
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(
          Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.1), lineWidth: 1))
  }

  /// 紧凑数字，与 Intl compact 一致：一万以上显示为“1.2万”，整数不带小数
  static func count(_ plays: Int) -> String {
    guard plays >= 10_000 else { return "\(plays)" }
    let value = (Double(plays) / 1_000).rounded() / 10
    return value == value.rounded() ? "\(Int(value))万" : String(format: "%.1f万", value)
  }
}

/// 第一名卡片：静止 primary/8，按下取原版 hover 的 primary/11
private struct NativeStatsLeaderStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(
      Color.nativePrimary.opacity(configuration.isPressed ? 0.11 : 0.08),
      in: RoundedRectangle(cornerRadius: 16)
    ).animation(.easeOut(duration: 0.2), value: configuration.isPressed)
  }
}
