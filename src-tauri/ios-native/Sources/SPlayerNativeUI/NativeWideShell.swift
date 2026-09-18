import SwiftUI

private enum WidePage: String, CaseIterable {
    case home = "首页", search = "搜索", library = "音乐库", artists = "艺术家", albums = "专辑"
    case folders = "文件夹", stats = "统计", liked = "我喜欢的音乐", favorites = "我的收藏"
    case cloud = "我的云盘", streaming = "媒体源", history = "播放历史", settings = "全局设置"

    var icon: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .library: return "music.note.list"
        case .artists: return "person"
        case .albums: return "opticaldisc"
        case .folders: return "folder"
        case .stats: return "chart.bar"
        case .liked: return "heart"
        case .favorites: return "star"
        case .cloud: return "icloud"
        case .streaming: return "externaldrive"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// 宽屏沿用原版侧栏、顶栏和底部播放栏的层级，不套用手机 Tab 布局。
@MainActor
struct NativeWideShell: View {
    @ObservedObject var player: NativePlayerStore
    @Binding var favorites: String
    @Binding var appearance: String
    let importMusic: () -> Void
    let showPlayer: () -> Void
    let showQueue: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: WidePage = .home
    @State private var previous: WidePage?
    @State private var search = ""
    @State private var selectedArtist: String?
    @State private var removeTrack: NativeTrack?

    private var dark: Bool { colorScheme == .dark }
    private var canvas: Color { dark ? Color(white: 0.07) : Color(white: 0.965) }
    private var panel: Color { dark ? Color(white: 0.10) : .white }
    private var border: Color { Color.primary.opacity(0.10) }
    private var favoriteSet: Set<String> { Set(favorites.split(separator: ",").map(String.init)) }
    private var liked: [NativeTrack] { player.tracks.filter { favoriteSet.contains($0.id.uuidString) } }
    private var artists: [String] { Array(Set(player.tracks.map(\.artist))).sorted() }
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 220).background(panel)
                Rectangle().fill(border).frame(width: 1)
                VStack(spacing: 0) {
                    topbar
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if page == .home { dashboard }
                            else { pageContent }
                        }.padding(24).frame(maxWidth: 1400, alignment: .leading).frame(maxWidth: .infinity)
                    }.accessibilityIdentifier("native.wide.content")
                }.background(canvas)
            }
            Rectangle().fill(border).frame(height: 1)
            playbackBar
        }
        .foregroundStyle(.primary).tint(.primary)
        .accessibilityIdentifier("native.wide.shell")
        .confirmationDialog("删除这首歌曲？", isPresented: Binding(get: { removeTrack != nil }, set: { if !$0 { removeTrack = nil } }), titleVisibility: .visible) {
            Button("删除应用内副本", role: .destructive) {
                if let track = removeTrack { Task { await player.remove(track) } }
                removeTrack = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                NativeLogo().frame(width: 30, height: 30)
                Text("SPlayer").font(.title3.weight(.semibold))
            }.frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach([WidePage.home, .library, .artists, .albums, .folders, .stats], id: \.self) { item in nav(item) }
                    Divider().padding(.vertical, 8)
                    ForEach([WidePage.liked, .favorites, .cloud, .streaming, .history], id: \.self) { item in nav(item) }
                    Divider().padding(.vertical, 8)
                    HStack {
                        Text("我的歌单").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                    Text("暂无歌单").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                }.padding(.horizontal, 10)
            }
        }.accessibilityIdentifier("native.wide.sidebar")
    }

    private func nav(_ item: WidePage) -> some View {
        Button { navigate(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon).frame(width: 18)
                Text(item.rawValue).font(.system(size: 14))
                Spacer()
            }.padding(.horizontal, 12).frame(minHeight: 44)
                .background(page == item ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .leading) {
                    if page == item { RoundedRectangle(cornerRadius: 1).fill(Color.primary).frame(width: 2, height: 22).padding(.leading, 2) }
                }
        }.buttonStyle(.plain).accessibilityIdentifier("native.wide.nav." + item.rawValue)
    }

    private var topbar: some View {
        HStack(spacing: 12) {
            Button {
                if let previous { page = previous; self.previous = nil }
            } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36).background(Color.primary.opacity(0.04), in: Circle()) }
                .disabled(previous == nil).accessibilityLabel("返回")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索歌曲、歌手", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { navigate(.search) }.accessibilityIdentifier("native.wide.search")
            }.padding(.horizontal, 14).frame(width: 260, height: 36)
                .background(Color.primary.opacity(0.03), in: Capsule()).overlay(Capsule().stroke(border, lineWidth: 1))
            Spacer()
            Label("本地音乐", systemImage: "person.crop.circle").font(.caption)
                .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04), in: Capsule())
            Button { navigate(.settings) } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                .accessibilityLabel("全局设置").accessibilityIdentifier("native.wide.settings")
        }.buttonStyle(.plain).padding(.horizontal, 20).frame(height: 64)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(greeting).font(.system(size: 28, weight: .bold))
                    Text("开始今天的音乐时光").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                metric(String(player.tracks.count), "首", "本地歌曲")
                metric(String(artists.count), "位", "艺术家")
                metric(String(liked.count), "首", "喜欢的音乐")
            }
            hero
            HStack(spacing: 12) {
                quickAction("试试手气", "随机播放一首", icon: "dice", enabled: !player.tracks.isEmpty) {
                    if let track = player.tracks.randomElement() { player.play(track, in: player.tracks) }
                }
                quickAction("每日推荐", "在线推荐尚未接入", icon: "calendar", enabled: false) {}
                quickAction("心动模式", "播放喜欢的音乐", icon: "heart", enabled: !liked.isEmpty) {
                    if let track = liked.randomElement() { player.play(track, in: liked) }
                }
                quickAction("私人 FM", "在线电台尚未接入", icon: "radio", enabled: false) {}
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("最近添加").font(.title3.bold())
                Text("让收藏的声音再次响起").font(.caption).foregroundStyle(.secondary)
            }
            if player.tracks.isEmpty {
                HStack {
                    Image(systemName: "music.note.list").font(.title2)
                    Text("还没有音乐，先导入你喜欢的歌曲吧。").foregroundStyle(.secondary)
                    Spacer()
                    Button("导入音乐", action: importMusic).disabled(player.importing)
                }.padding(20).frame(maxWidth: .infinity).background(panel, in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Array(player.tracks.suffix(8).reversed())) { track in
                        Button { player.play(track, in: player.tracks) } label: { NativeTrackRow(track: track, selected: player.current?.id == track.id).padding(12) }
                            .buttonStyle(.plain).background(panel, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 20) {
            NativeLogo().padding(30).frame(width: 150, height: 150)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 10) {
                Text("本地音乐").font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Text(player.current?.title ?? "从你喜欢的音乐，听起").font(.title2.bold()).lineLimit(2)
                Text(player.current?.artist ?? "导入歌曲后即可离线收听").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        if let track = player.current ?? player.tracks.first { player.play(track, in: player.tracks) }
                    } label: { Label("立即播放", systemImage: "play.circle").padding(.horizontal, 10).frame(height: 36) }
                        .buttonStyle(.plain).background(Color.primary, in: Capsule()).foregroundStyle(panel)
                        .disabled(player.tracks.isEmpty)
                    Button(action: importMusic) { Label("导入音乐", systemImage: "plus").padding(.horizontal, 10).frame(height: 36) }
                        .buttonStyle(.plain).background(Color.primary.opacity(0.06), in: Capsule())
                        .disabled(player.importing).accessibilityIdentifier("native.import.wide")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !player.tracks.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(player.tracks.prefix(4).enumerated()), id: \.element.id) { index, track in
                        Button { player.play(track, in: player.tracks) } label: {
                            HStack {
                                Text(String(format: "%02d", index + 1)).foregroundStyle(.tertiary).monospacedDigit()
                                Text(track.title).lineLimit(1)
                                Spacer()
                            }.font(.caption)
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: 210)
            }
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(border, lineWidth: 1))
    }

    @ViewBuilder private var pageContent: some View {
        Text(page.rawValue).font(.system(size: 28, weight: .bold)).accessibilityIdentifier("native.wide.pageTitle")
        switch page {
        case .library, .liked, .search:
            let values = page == .liked ? liked : page == .search ? player.tracks.filter { search.isEmpty || ($0.title + $0.artist).localizedCaseInsensitiveContains(search) } : player.tracks
            library(values)
        case .artists:
            if let selectedArtist {
                Button("全部艺术家") { self.selectedArtist = nil }
                library(player.tracks.filter { $0.artist == selectedArtist })
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 20) {
                    ForEach(artists, id: \.self) { artist in
                        Button { selectedArtist = artist } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "person.fill").font(.system(size: 48)).frame(width: 112, height: 112).background(Color.primary.opacity(0.05), in: Circle())
                                Text(artist).font(.headline)
                                Text("\(player.tracks.filter { $0.artist == artist }.count) 首歌曲").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding()
                        }.buttonStyle(.plain)
                    }
                }
                if artists.isEmpty { Text("导入歌曲后在这里查看艺术家。").foregroundStyle(.secondary) }
            }
        case .folders:
            Button { navigate(.library) } label: { Label("本地音乐 · \(player.tracks.count) 首", systemImage: "folder").padding(20) }.buttonStyle(.bordered)
        case .stats:
            HStack(spacing: 32) {
                metric(String(player.tracks.count), "首", "本地歌曲")
                metric(String(artists.count), "位", "艺术家")
                metric(String(Int(player.tracks.reduce(0) { $0 + $1.durationMs } / 60000)), "分钟", "曲库总时长")
            }
        case .settings:
            VStack(alignment: .leading, spacing: 24) {
                settingsRow("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }.frame(maxWidth: 260)
                }
                settingsRow("播放") { Toggle("单曲循环", isOn: $player.repeatOne).frame(maxWidth: 220) }
                settingsRow("本地音乐") {
                    Button("导入音乐", action: importMusic).disabled(player.importing).accessibilityIdentifier("native.import.wide.settings")
                }
                Text("删除曲库中的歌曲只删除应用内副本，不影响原文件。").font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(spacing: 16) {
                Image(systemName: page.icon).font(.system(size: 42)).foregroundStyle(.tertiary)
                Text("\(page.rawValue)尚未接入原生版本").font(.headline)
                Text("当前可导入本地音乐收听，已有账号和云端内容仍请在原版使用。").font(.subheadline).foregroundStyle(.secondary)
                Button("查看本地音乐") { navigate(.library) }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity).padding(.vertical, 80)
        }
    }

    private func library(_ tracks: [NativeTrack]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    if let first = tracks.first { player.play(first, in: tracks) }
                } label: { Label("播放全部", systemImage: "play.fill") }.disabled(tracks.isEmpty)
                Button(action: importMusic) { Label("导入音乐", systemImage: "plus") }.disabled(player.importing)
                Spacer()
                Text("共 \(tracks.count) 首歌曲").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            Divider()
            if tracks.isEmpty { Text("暂无歌曲，导入音乐后即可收听。").foregroundStyle(.secondary).padding(.vertical, 40) }
            LazyVStack(spacing: 4) {
                ForEach(tracks) { track in
                    HStack {
                        Button { player.play(track, in: tracks) } label: { NativeTrackRow(track: track, selected: player.current?.id == track.id) }.buttonStyle(.plain)
                        Button { toggleFavorite(track) } label: { Image(systemName: favoriteSet.contains(track.id.uuidString) ? "heart.fill" : "heart").frame(width: 44, height: 44) }
                            .accessibilityLabel(favoriteSet.contains(track.id.uuidString) ? "取消喜欢" : "喜欢")
                        Menu {
                            Button("删除", role: .destructive) { removeTrack = track }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    }.padding(.horizontal, 12).padding(.vertical, 4).background(panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 20) {
            Button(action: showPlayer) {
                HStack(spacing: 12) {
                    NativeLogo().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(player.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(width: 240)
            }.buttonStyle(.plain).disabled(player.current == nil)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(action: showQueue) { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放队列")
                Button(action: player.previous) { Image(systemName: "backward.end").frame(width: 44, height: 44) }.accessibilityLabel("上一首")
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44).background(Color.primary.opacity(0.08), in: Circle())
                }.accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Button(action: player.next) { Image(systemName: "forward.end").frame(width: 44, height: 44) }.accessibilityLabel("下一首")
                Button { player.repeatOne.toggle() } label: { Image(systemName: player.repeatOne ? "repeat.1" : "repeat").frame(width: 44, height: 44) }.accessibilityLabel("单曲循环")
            }.buttonStyle(.plain).disabled(player.current == nil)
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                Text(NativeNowPlayingView.time(player.positionMs) + " / " + NativeNowPlayingView.time(player.durationMs)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { player.positionMs }, set: { player.seek(to: $0) }), in: 0...max(1, player.durationMs))
                    .disabled(player.current == nil).accessibilityLabel("播放进度")
            }.frame(width: 140)
        }.padding(.horizontal, 20).frame(height: 78).background(panel).accessibilityIdentifier("native.wide.playerbar")
    }

    private func metric(_ value: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) { Text(value).font(.title2.bold()); Text(unit).font(.caption) }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.padding(.leading, 12)
    }

    private func quickAction(_ title: String, _ subtitle: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 32, height: 32).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 62).background(panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack { Text(title).font(.headline); Spacer(); content() }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func navigate(_ target: WidePage) { if page != target { previous = page; page = target; selectedArtist = nil } }
    private func toggleFavorite(_ track: NativeTrack) {
        var ids = favoriteSet
        if ids.contains(track.id.uuidString) { ids.remove(track.id.uuidString) } else { ids.insert(track.id.uuidString) }
        favorites = ids.sorted().joined(separator: ",")
    }
}
