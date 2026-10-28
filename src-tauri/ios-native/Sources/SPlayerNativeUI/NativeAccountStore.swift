import ImageIO
import SwiftUI

/// 网易云账号信息，字段与共享服务的 account 动作一致
struct NativeAccount: Decodable, Equatable {
  let userId: Int
  let nickname: String
  let avatarUrl: String?
  let signature: String?
  let vipType: Int
  let level: Int?
  let playlistCount: Int
  let albumCount: Int
  let artistCount: Int
  /// 「我喜欢的音乐」歌单
  let liked: NativeCover?
  /// 自建歌单，不含「我喜欢的音乐」
  let created: [NativeCover]
  let subscribed: [NativeCover]
  let albums: [NativeCover]
  let artists: [NativeCover]

  var isVip: Bool { vipType != 0 }
}

/// 登录后的账号状态，对应原版 user store：资料、等级、收藏计数、歌单分组与在线喜欢
@MainActor
final class NativeAccountStore: ObservableObject {
  @Published private(set) var account: NativeAccount?
  /// 在线「我喜欢的音乐」曲目，只保留当前账号一份
  @Published private(set) var likedTracks: [NativeTrack] = []
  @Published private(set) var loadingLiked = false
  @Published var likedError: String?
  /// 我的收藏页当前分类：playlist / album / artist
  @Published var favoritesTab = "playlist"
  private let service: NativeOnlineService
  private var generation = 0
  private var likedFor: String?

  init(service: NativeOnlineService) { self.service = service }

  /// 拉取账号信息；网络失败时保留上次结果，服务端确认未登录时清空
  func refresh() async {
    generation += 1
    let token = generation
    do {
      let raw = try await service.call(["action": "account"])
      guard token == generation else { return }
      if let raw = raw as? [String: Any] {
        account = try JSONDecoder().decode(
          NativeAccount.self, from: JSONSerialization.data(withJSONObject: raw))
      } else {
        clear()
      }
    } catch is CancellationError {} catch {
      if token == generation, account == nil { clear() }
    }
  }

  /// 退出网易云：结束服务端会话并清除本地 cookie
  func logout() async throws {
    _ = try await service.call(["action": "logout"])
    generation += 1
    clear()
  }

  /// 拉取在线「我喜欢的音乐」；同一歌单已加载时不重复请求
  /// @param refresh - 是否强制重新拉取
  func loadLiked(refresh: Bool = false) async {
    guard let liked = account?.liked, !loadingLiked else { return }
    if !refresh, likedFor == liked.id, !likedTracks.isEmpty { return }
    loadingLiked = true
    likedError = nil
    defer { loadingLiked = false }
    do {
      let raw =
        try await service.call(["action": "playlist", "id": liked.id]) as? [String: Any] ?? [:]
      guard account?.liked?.id == liked.id else { return }
      likedTracks = (raw["tracks"] as? [[String: Any]] ?? []).compactMap(NativeTrack.online)
      likedFor = liked.id
    } catch is CancellationError {} catch { likedError = error.localizedDescription }
  }

  private func clear() {
    account = nil
    likedTracks = []
    likedFor = nil
  }
}

/// 原版顶栏使用的黑胶 VIP 标识图片
struct NativeVipBadge: View {
  var height: CGFloat = 16
  private static let image: CGImage? = {
    guard let url = Bundle.module.url(forResource: "vip", withExtension: "png"),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }()
  var body: some View {
    if let image = Self.image {
      Image(decorative: image, scale: 1).resizable().scaledToFit().frame(height: height)
        .accessibilityLabel("VIP")
    }
  }
}

/// 等级标签，与原版琥珀色 Lv 胶囊一致
struct NativeLevelBadge: View {
  let level: Int
  var body: some View {
    Text("Lv.\(level)").font(.system(size: 10, weight: .semibold).monospacedDigit())
      .padding(.horizontal, 6).padding(.vertical, 3)
      .background(Color.orange.opacity(0.15), in: Capsule())
      .foregroundStyle(Color.orange)
  }
}

/// 圆形头像，未提供时显示占位图标
struct NativeAvatar: View {
  let url: String?
  let size: CGFloat
  var body: some View {
    Group {
      if let url, !url.isEmpty {
        NativeArtwork(cover: url, radius: size / 2)
      } else {
        Image(systemName: "person.fill").font(.system(size: size * 0.45))
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.primary.opacity(0.1), in: Circle())
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}

/// 顶栏账号入口：未登录为图标按钮，登录后为头像胶囊并弹出资料卡，对应原版 NavUser
@MainActor
struct NativeAccountButton: View {
  @ObservedObject var account: NativeAccountStore
  /// 窗口 <1200 时只显示 32 头像，隐藏昵称、VIP 与箭头
  var avatarOnly = false
  /// 打开平台账号页（扫码登录与其他平台）
  let manage: () -> Void
  /// 点击收藏计数时打开我的收藏
  let favorites: () -> Void
  @State private var open = false

  var body: some View {
    if let user = account.account {
      Button {
        open = true
      } label: {
        HStack(spacing: 8) {
          NativeAvatar(url: user.avatarUrl, size: 32)
          if !avatarOnly {
            Text(user.nickname).font(.system(size: 14)).lineLimit(1).frame(maxWidth: 112)
              .fixedSize()
            if user.isVip { NativeVipBadge() }
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(open ? 180 : 0))
          }
        }.padding(.leading, 4).padding(.trailing, avatarOnly ? 4 : 12).frame(height: 40)
          .nativeGlass(in: Capsule()).contentShape(Capsule())
      }.buttonStyle(.plain).accessibilityLabel("账号：" + user.nickname)
        .accessibilityIdentifier("native.account.pill")
        .popover(isPresented: $open, arrowEdge: .top) {
          NativeAccountCard(
            account: account, user: user,
            manage: {
              open = false
              manage()
            },
            favorites: { tab in
              open = false
              account.favoritesTab = tab
              favorites()
            })
        }
    } else {
      NativeIconButton(icon: "person.crop.circle", title: "平台账号", action: manage)
    }
  }
}

/// 账号资料卡：头像、昵称、等级与 VIP、签名、收藏计数和退出登录
@MainActor
struct NativeAccountCard: View {
  @ObservedObject var account: NativeAccountStore
  let user: NativeAccount
  let manage: () -> Void
  let favorites: (String) -> Void
  @State private var confirmLogout = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 10) {
      NativeAvatar(url: user.avatarUrl, size: 48)
      Text(user.nickname).font(.system(size: 15, weight: .semibold)).lineLimit(1)
      if user.level != nil || user.isVip {
        HStack(spacing: 6) {
          if let level = user.level { NativeLevelBadge(level: level) }
          if user.isVip { NativeVipBadge() }
        }
      }
      if let signature = user.signature, !signature.isEmpty {
        Text(signature).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .lineLimit(2)
      }
      Divider()
      HStack(spacing: 4) {
        stat("playlist", icon: "music.note.list", value: user.playlistCount, label: "歌单")
        stat("album", icon: "opticaldisc", value: user.albumCount, label: "专辑")
        stat("artist", icon: "person", value: user.artistCount, label: "歌手")
      }
      Divider()
      Button(action: manage) {
        Label("平台账号", systemImage: "person.2").frame(maxWidth: .infinity)
      }.buttonStyle(.bordered)
      Button(role: .destructive) {
        confirmLogout = true
      } label: {
        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
          .frame(maxWidth: .infinity)
      }.buttonStyle(.bordered).accessibilityIdentifier("native.account.logout")
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .padding(16).frame(width: 240)
    .confirmationDialog("确认退出当前账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
      Button("退出登录", role: .destructive) {
        Task {
          do { try await account.logout() } catch { self.error = error.localizedDescription }
        }
      }
    }
  }

  private func stat(_ tab: String, icon: String, value: Int, label: String) -> some View {
    Button {
      favorites(tab)
    } label: {
      VStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary)
        Text("\(value)").font(.system(size: 14, weight: .semibold).monospacedDigit())
      }.frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("\(label) \(value)")
  }
}
