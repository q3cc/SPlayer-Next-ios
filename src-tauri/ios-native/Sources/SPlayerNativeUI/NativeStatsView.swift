import Charts
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

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width - 48
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("统计").font(.system(size: 30, weight: .bold))
          overview(columns: width >= 860 ? 5 : width >= 640 ? 3 : 2)
          if width >= 1200 {
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
          let columns = width >= 1200 ? 3 : width >= 640 ? 2 : 1
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: columns),
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
              title: "最常听的歌手", icon: "person", circle: true, items: artists, subtitle: { _ in nil }
            ) { _ in navigate(.artists) }
          }
        }.padding(24).frame(maxWidth: 1400).frame(maxWidth: .infinity)
      }
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

  /// 概览卡片：大号数字配单位，右下角衬底图标
  private func overviewCard(
    _ label: String, icon: String, value: String?, unit: String? = nil, value2: String? = nil,
    unit2: String? = nil, action: (() -> Void)? = nil
  ) -> some View {
    Button {
      action?()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
          Text(value ?? "--").font(.system(size: 30, weight: .bold).monospacedDigit())
          if let unit, value != nil {
            Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
          }
          if let value2 {
            Text(value2).font(.system(size: 30, weight: .bold).monospacedDigit())
            if let unit2 {
              Text(unit2).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            }
          }
        }
        Text(label).font(.system(size: 12)).foregroundStyle(.secondary.opacity(0.7))
      }
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .bottomLeading)
      .padding(20)
      .background(alignment: .bottomTrailing) {
        Image(systemName: icon).font(.system(size: 56)).foregroundStyle(Color.primary.opacity(0.08))
          .rotationEffect(.degrees(-14)).offset(x: 8, y: 12)
      }
      .background(Color.nativePanel).clipShape(RoundedRectangle(cornerRadius: 16))
      .contentShape(RoundedRectangle(cornerRadius: 16))
    }.buttonStyle(.plain).allowsHitTesting(action != nil)
  }

  private var heatmap: some View {
    card(title: "聆听足迹", trailing: "近 90 天") { NativeStatsHeatmap(daily: daily) }
  }

  private var hours: some View {
    card(title: "播放时段") { NativeStatsHours(hourly: hourly) }
  }

  private var formats: some View {
    card(
      title: "音频格式",
      trailing: library.map { "\(min(4, $0.codecs.count)) 种格式" } ?? "--"
    ) { NativeStatsFormats(library: library) }
  }

  /// 统一的统计卡片外框，高度与原版 h-52 一致
  private func card<Content: View>(
    title: String, trailing: String? = nil, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 16, weight: .semibold))
        Spacer()
        if let trailing {
          Text(trailing).font(.system(size: 12).monospacedDigit()).foregroundStyle(
            .secondary.opacity(0.6))
        }
      }
      content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(16).frame(height: 208).frame(maxWidth: .infinity)
    .background(Color.nativePanel, in: RoundedRectangle(cornerRadius: 16))
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
    VStack(spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .trailing, spacing: 2) {
          Color.clear.frame(width: 1, height: 20)
          ForEach(0..<7, id: \.self) { dow in
            Text([1, 3, 5].contains(dow) ? ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][dow] : "")
              .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7)).frame(height: cell)
          }
        }
        HStack(alignment: .top, spacing: 2) {
          ForEach(0..<weeks, id: \.self) { week in
            VStack(spacing: 2) {
              Text(months[week] ?? "").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7))
                .fixedSize().frame(width: cell, height: 20)
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
      }
      HStack(spacing: 8) {
        Text("少")
        ForEach(1...5, id: \.self) { level in
          RoundedRectangle(cornerRadius: 3)
            .fill(Self.color(Int((Double(level) / 5 * Double(peak)).rounded()), peak: peak))
            .frame(width: 12, height: 12)
        }
        Text("多")
      }.font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7))
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

  /// 无播放为 6% 底色，其余按峰值比例 14%–86%
  static func color(_ count: Int, peak: Int) -> Color {
    guard count > 0, peak > 0 else { return Color.primary.opacity(0.06) }
    return Color.primary.opacity(0.14 + Double(count) / Double(peak) * 0.72)
  }
}

/// 播放时段折线：平滑曲线与面积，最高点标出“最常播放”
struct NativeStatsHours: View {
  let hourly: [Int]

  var body: some View {
    let total = hourly.reduce(0, +)
    let peak = hourly.indices.max { hourly[$0] < hourly[$1] }
    // 单调插值保持平滑且不会在零值附近下探到基线以下
    VStack(spacing: 6) {
      ZStack {
        if total > 0 {
          Chart {
            ForEach(Array(hourly.enumerated()), id: \.offset) { hour, count in
              AreaMark(x: .value("时段", hour), y: .value("播放", count))
                .interpolationMethod(.monotone).foregroundStyle(Color.primary.opacity(0.08))
              LineMark(x: .value("时段", hour), y: .value("播放", count))
                .interpolationMethod(.monotone).foregroundStyle(Color.primary)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let peak {
              PointMark(x: .value("时段", peak), y: .value("播放", hourly[peak]))
                .foregroundStyle(Color.primary).symbolSize(50)
                .annotation(position: .top, spacing: 6) {
                  VStack(spacing: 3) {
                    Text("最常播放").font(.system(size: 9, weight: .medium)).opacity(0.8)
                    Text(String(format: "%02d:00", peak)).font(.system(size: 12, weight: .bold))
                  }.foregroundStyle(Color.nativeCanvas).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
          }
          .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
          .chartXScale(domain: 0...23)
          .chartYScale(domain: 0...Double(max(1, hourly.max() ?? 1)) * 1.35)
        } else {
          Text("暂无播放时段数据").font(.system(size: 14)).foregroundStyle(.secondary.opacity(0.6))
        }
      }.frame(maxHeight: .infinity)
      HStack {
        ForEach(["00", "06", "12", "18", "24"], id: \.self) { label in
          Text(label)
          if label != "24" { Spacer() }
        }
      }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary.opacity(0.6))
      if total > 0, let peak {
        Text("你最喜欢在 \(String(format: "%02d", peak)):00 听歌，共计 \(hourly[peak]) 首")
          .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
      }
    }
  }
}

/// 音频格式圆环：最多四种格式，中间显示无损占比
struct NativeStatsFormats: View {
  let library: NativeLibraryStats?

  var body: some View {
    let codecs = Array((library?.codecs ?? []).prefix(4))
    let total = codecs.reduce(0) { $0 + $1.count }
    if let library, !library.codecs.isEmpty, total > 0 {
      let lossless = codecs.filter { NativeStatsMath.losslessCodecs.contains($0.codec) }
        .reduce(0) { $0 + $1.count }
      HStack(spacing: 16) {
        ZStack {
          ForEach(Array(codecs.enumerated()), id: \.offset) { index, item in
            let start = Double(codecs.prefix(index).reduce(0) { $0 + $1.count }) / Double(total)
            let end = start + Double(item.count) / Double(total)
            // 段间留 2pt 缝隙，与原版圆环一致
            let gap = codecs.count > 1 ? 2 / (2 * Double.pi * 46) / 2 : 0
            Circle().trim(from: start + gap, to: max(start + gap, end - gap))
              .stroke(Color.primary.opacity(Self.opacity(index)), lineWidth: 16)
              .rotationEffect(.degrees(-90))
          }
          VStack(spacing: 4) {
            Text("无损占比").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(String(format: "%.1f%%", Double(lossless) / Double(total) * 100))
              .font(.system(size: 20, weight: .bold).monospacedDigit())
          }
        }.frame(width: 92, height: 92).padding(18)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
          ForEach(Array(codecs.enumerated()), id: \.offset) { index, item in
            HStack(spacing: 8) {
              Circle().fill(Color.primary.opacity(Self.opacity(index))).frame(width: 8, height: 8)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.codec.uppercased()).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(
                  "\(item.count) 首 · \(String(format: "%.1f%%", Double(item.count) / Double(total) * 100))"
                ).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer(minLength: 0)
            }
          }
        }
      }.frame(maxWidth: 520)
    } else if library == nil {
      ProgressView()
    } else {
      VStack(spacing: 8) {
        Image(systemName: "music.note").font(.system(size: 26))
        Text("暂无数据，去听一些歌吧").font(.system(size: 14))
      }.foregroundStyle(.secondary.opacity(0.6))
    }
  }

  static func opacity(_ index: Int) -> Double { max(0.24, 0.92 - Double(index) * 0.14) }
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
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 18)).frame(width: 40, height: 40)
          .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 16, weight: .semibold))
          Text("TOP \(items.count)").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.7))
        }
      }
      if let first = items.first {
        Button {
          open(first)
        } label: {
          HStack(spacing: 12) {
            cover(first, size: 80)
            VStack(alignment: .leading, spacing: 4) {
              Text(first.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                .padding(.trailing, 44)
              if let text = subtitle(first) {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer(minLength: 0)
              HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Self.count(first.plays)).font(.system(size: 30, weight: .bold).monospacedDigit())
                Text("次播放").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 6).frame(height: 80)
            Spacer(minLength: 0)
          }
          .overlay(alignment: .topTrailing) {
            Text("TOP 1").font(.system(size: 12, weight: .bold)).tracking(1).padding(.top, 4)
          }
          .padding(12).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
          .contentShape(Rectangle())
        }.buttonStyle(.plain)
        VStack(spacing: 0) {
          ForEach(Array(items.dropFirst().enumerated()), id: \.element.id) { index, item in
            Button {
              open(item)
            } label: {
              HStack(spacing: 8) {
                Text(String(format: "%02d", index + 2)).font(.system(size: 12, weight: .bold).monospacedDigit())
                  .foregroundStyle(.secondary.opacity(0.7)).frame(width: 20)
                cover(item, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                  if let text = subtitle(item) {
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                  Text(Self.count(item.plays)).font(.system(size: 20, weight: .bold).monospacedDigit())
                  Text("次播放").font(.system(size: 10)).foregroundStyle(.secondary)
                }
              }.padding(6).frame(minHeight: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
      } else {
        VStack(spacing: 8) {
          Image(systemName: icon).font(.system(size: 26))
          Text("暂无播放数据").font(.system(size: 14))
        }.foregroundStyle(.secondary.opacity(0.6)).frame(maxWidth: .infinity, minHeight: 224)
          .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
      }
    }.padding(16).background(Color.nativePanel, in: RoundedRectangle(cornerRadius: 16))
  }

  private func cover(_ item: NativeRankItem, size: CGFloat) -> some View {
    NativeArtwork(cover: item.track.cover, radius: circle ? size / 2 : size > 50 ? 12 : 8)
      .frame(width: size, height: size)
  }

  /// 紧凑数字：一万以上显示为“1.2万”
  static func count(_ plays: Int) -> String {
    plays >= 10_000 ? String(format: "%.1f万", Double(plays) / 10_000) : "\(plays)"
  }
}
