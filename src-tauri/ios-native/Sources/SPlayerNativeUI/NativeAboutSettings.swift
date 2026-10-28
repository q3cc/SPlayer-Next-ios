import CoreText
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// 构建信息：版本取自应用包，提交由 prepare.sh 写入 build-info.json
enum NativeBuildInfo {
  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.0"
  static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
  private static let info: [String: String] = {
    guard let url = Bundle.module.url(forResource: "build-info", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [:] }
    return value
  }()
  static let commit = info["commit"] ?? "unknown"
  static let date = info["date"] ?? "unknown"

  /// 系统与架构，对应原版环境信息中的 OS 行
  static var system: String {
    #if os(iOS)
      let device = UIDevice.current
      return "\(device.systemName) \(device.systemVersion) arm64 · \(device.model)"
    #else
      return "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
    #endif
  }
}

/// 关于软件，与 main 的 `AboutSettings.vue` 一致：关于、特别致谢、开发人员、社区与资讯、环境信息
@MainActor
struct NativeAboutSettings: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.horizontalSizeClass) private var sizeClass
  /// 即使 GitHub 限流，iOS 作者署名也保留
  private static let iosAuthor = NativeContributor(
    login: "q3cc", htmlUrl: "https://github.com/q3cc",
    avatar: "https://avatars.githubusercontent.com/u/106431792?v=4")
  /// iOS 版本的署名作者；原版项目以版权所有者为作者
  private static let iosAuthors: Set<String> = ["q3cc", "imsyy"]
  private static let copyrightHolder = "imsyy"
  private static let dependencies = [
    ("SPlayer-Next", "原版项目与桌面端实现", "https://github.com/SPlayer-Dev/SPlayer-Next"),
    (
      "applemusic-like-lyrics", "类 Apple Music 歌词显示组件库",
      "https://github.com/Steve-xmh/applemusic-like-lyrics"
    ),
    (
      "NeteaseCloudMusicApiEnhanced", "网易云音乐 API 备份 + 增强",
      "https://github.com/neteasecloudmusicapienhanced/api-enhanced"
    ),
  ]

  @State private var iosDevelopers = [Self.iosAuthor]
  @State private var originalDevelopers: [NativeContributor] = []
  @State private var allIos = false
  @State private var allOriginal = false
  @State private var checking = false
  @State private var release: NativeRelease?
  @State private var showRelease = false
  @State private var updateMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        section("关于软件") {
          HStack(spacing: 16) {
            NativeLogo().frame(width: 34, height: 34)
            HStack(spacing: 8) {
              Text("SPlayer-Next-ios").font(.custom("Poppins-Medium", size: 18))
                .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
              NativeSettingTag(text: "v" + NativeBuildInfo.version, size: .small, round: true)
            }
            Spacer(minLength: 0)
            Button {
              Task { await checkUpdate() }
            } label: {
              HStack(spacing: 6) {
                if checking {
                  ProgressView().controlSize(.small)
                } else {
                  Image(systemName: "arrow.clockwise").font(.system(size: 18))
                }
                Text(release != nil ? "发现新版本" : checking ? "检查中" : "检查更新")
              }
            }.buttonStyle(NativeButtonStyle()).disabled(checking)
              .accessibilityIdentifier("native.about.checkUpdate")
          }.nativeAboutCard(radius: 12)
        }
        section("特别致谢") {
          LazyVGrid(columns: columns(3), spacing: 10) {
            ForEach(Self.dependencies, id: \.0) { name, description, url in
              Button {
                if let url = URL(string: url) { openURL(url) }
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    Text(name).font(.system(size: 14, weight: .medium))
                      .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.system(size: 12))
                      .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.4))
                  }
                  Text(description).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.7))
                }.frame(maxWidth: .infinity, alignment: .leading).nativeAboutCard()
              }.buttonStyle(NativePressStyle())
            }
          }
        }
        section("开发人员") {
          VStack(alignment: .leading, spacing: 16) {
            developers(
              "iOS 版本贡献者", iosDevelopers, expanded: $allIos, iosVersion: true,
              identifier: "native.about.iosContributors")
            if !originalDevelopers.isEmpty {
              developers(
                "原版项目贡献者", originalDevelopers, expanded: $allOriginal, iosVersion: false,
                identifier: "native.about.originalContributors")
            }
          }
        }
        section("社区与资讯") {
          LazyVGrid(columns: columns(3), spacing: 10) {
            communityLink("SPlayer-Next-ios", icon: "chevron.left.forwardslash.chevron.right") {
              openURL(NativeGitHub.repoURL)
            }
            communityLink("官方网站", icon: "dot.radiowaves.up.forward") {
              openURL(NativeGitHub.repoURL)
            }
            NavigationLink {
              NativeLicensesView().nativeSettingsPage()
            } label: {
              communityLabel("开源许可", icon: "doc.text")
            }.buttonStyle(NativePressStyle())
          }
        }
        section("环境信息") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(environment, id: \.0) { label, value, url in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label + ":").foregroundStyle(Color.nativeOnSurface.opacity(0.6))
                if let url {
                  Button {
                    openURL(url)
                  } label: {
                    HStack(spacing: 4) {
                      Text(value)
                      Image(systemName: "arrow.up.right").font(.system(size: 12))
                    }.foregroundStyle(Color.nativeOnSurface)
                  }.buttonStyle(.plain)
                } else {
                  Text(value).foregroundStyle(Color.nativeOnSurface).textSelection(.enabled)
                }
              }
            }
          }.font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
            .nativeAboutCard(radius: 12)
        } trailing: {
          Button {
            copyEnvironment()
          } label: {
            Image(systemName: "doc.on.doc")
          }.buttonStyle(NativeButtonStyle(variant: .ghost, size: .small, shape: .circle))
            .accessibilityLabel("复制环境信息")
        }
      }
      .padding(.horizontal, sizeClass == .compact ? 16 : 32).padding(.vertical, 24)
    }
    .background(Color.nativeSurface.ignoresSafeArea())
    .navigationTitle("关于软件")
    .task { await loadContributors() }
    .alert("发现新版本", isPresented: $showRelease) {
      Button("前往下载页") { if let release { openURL(release.page) } }
      Button("稍后", role: .cancel) {}
    } message: {
      Text("v\(release?.version ?? "")\n\n" + String((release?.notes ?? "").prefix(600)))
    }
    .alert(
      updateMessage ?? "",
      isPresented: Binding(get: { updateMessage != nil }, set: { if !$0 { updateMessage = nil } })
    ) {
      Button("好", role: .cancel) {}
    }
  }

  /// 原版 AboutSettings 的分区：竖条标题、下边距 12
  private func section<Content: View, Trailing: View>(
    _ title: String, @ViewBuilder content: () -> Content,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      NativeSettingHeader(title: title, trailing: trailing).padding(.horizontal, 4)
      content()
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    section(title, content: content) { EmptyView() }
  }

  /// 网格列：原版 grid-cols-3（开发人员窄宽 2 列）、gap-2.5
  private func columns(_ count: Int) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
  }

  private func communityLink(_ title: String, icon: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) { communityLabel(title, icon: icon) }.buttonStyle(NativePressStyle())
  }

  private func communityLabel(_ title: String, icon: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 17)).frame(width: 20, height: 20)
        .foregroundStyle(Color.nativeOnSurfaceVariant)
      Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.nativeOnSurface)
        .lineLimit(1)
      Spacer(minLength: 0)
    }.nativeAboutCard()
  }

  /// 原版环境信息：提交、日期、构建与系统
  private var environment: [(String, String, URL?)] {
    let date = ISO8601DateFormatter().date(from: NativeBuildInfo.date)
    let ago = date.map { value -> String in
      let formatter = RelativeDateTimeFormatter()
      formatter.locale = Locale(identifier: "zh-CN")
      return " (" + formatter.localizedString(for: value, relativeTo: Date()) + ")"
    } ?? ""
    return [
      (
        "提交", NativeBuildInfo.commit,
        NativeBuildInfo.commit == "unknown"
          ? nil : NativeGitHub.repoURL.appendingPathComponent("commit/" + NativeBuildInfo.commit)
      ),
      ("日期", NativeBuildInfo.date + ago, nil),
      ("构建", "\(NativeBuildInfo.version) (\(NativeBuildInfo.build)) · SwiftUI", nil),
      ("OS", NativeBuildInfo.system, nil),
    ]
  }

  /// 贡献者网格：默认展示前 6 位，其余折叠
  private func developers(
    _ title: String, _ items: [NativeContributor], expanded: Binding<Bool>, iosVersion: Bool,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 14)).foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6))
        .padding(.horizontal, 4)
      LazyVGrid(columns: columns(sizeClass == .compact ? 2 : 3), spacing: 10) {
        ForEach(expanded.wrappedValue ? items : Array(items.prefix(6))) { dev in
          Button {
            if let url = URL(string: dev.htmlUrl) { openURL(url) }
          } label: {
            HStack(spacing: 10) {
              NativeArtwork(cover: dev.avatar.isEmpty ? nil : dev.avatar, radius: 18)
                .frame(width: 36, height: 36)
              VStack(alignment: .leading, spacing: 0) {
                Text(dev.login).font(.system(size: 14, weight: .medium))
                  .foregroundStyle(Color.nativeOnSurface).lineLimit(1)
                Text(role(dev.login, iosVersion: iosVersion)).font(.system(size: 12))
                  .foregroundStyle(Color.nativeOnSurfaceVariant.opacity(0.6)).lineLimit(1)
              }
              Spacer(minLength: 0)
            }.nativeAboutCard(small: true)
          }.buttonStyle(NativePressStyle())
        }
      }.accessibilityIdentifier(identifier)
      if items.count > 6 {
        NativeSButton(
          title: expanded.wrappedValue ? "收起" : "更多贡献者",
          icon: expanded.wrappedValue ? "chevron.up" : "chevron.down", variant: .text, size: .small
        ) { expanded.wrappedValue.toggle() }
      }
    }
  }

  private func role(_ login: String, iosVersion: Bool) -> String {
    let name = login.lowercased()
    return (iosVersion && Self.iosAuthors.contains(name))
      || (!iosVersion && name == Self.copyrightHolder) ? "Author" : "Contributor"
  }

  /// 两组贡献者并行获取，任一失败不影响另一组；iOS 作者始终排在首位
  private func loadContributors() async {
    async let ios = try? NativeGitHub.contributors(
      NativeGitHub.iosRepo,
      compareBase: NativeGitHub.originalRepo.split(separator: "/")[0] + ":main")
    async let original = try? NativeGitHub.contributors(NativeGitHub.originalRepo)
    let (iosResult, originalResult) = await (ios, original)
    if let iosResult {
      let author = iosResult.first { $0.id == Self.iosAuthor.id } ?? Self.iosAuthor
      iosDevelopers = [author] + iosResult.filter { $0.id != Self.iosAuthor.id }
    }
    if let originalResult { originalDevelopers = originalResult }
  }

  /// 原生版本不在 Releases 发布安装包，发现新版本时只打开发布页
  private func checkUpdate() async {
    if release != nil {
      showRelease = true
      return
    }
    checking = true
    defer { checking = false }
    do {
      if let found = try await NativeGitHub.checkUpdate(current: NativeBuildInfo.version) {
        release = found
        showRelease = true
      } else {
        updateMessage = "已是最新版本"
      }
    } catch {
      updateMessage = "更新失败，请稍后重试：" + error.localizedDescription
    }
  }

  private func copyEnvironment() {
    let text = environment.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    #if os(iOS)
      UIPasteboard.general.string = text
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #endif
    updateMessage = "已复制环境信息"
  }
}

/// 随应用分发的第三方许可证全文
struct NativeLicensesView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(
          [
            "SPlayer-LICENSE", "QuickJS-LICENSE", "AMLL-LICENSE", "AudioStreaming-LICENSE",
            "MaterialColors-LICENSE", "GLMatrix-LICENSE",
          ], id: \.self
        ) { name in
          Text(name).font(.system(size: 16, weight: .semibold))
          if let url = Bundle.module.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
          {
            Text(text).font(.system(size: 12, design: .monospaced))
              .foregroundStyle(Color.nativeOnSurfaceVariant).textSelection(.enabled)
          }
        }
      }.foregroundStyle(Color.nativeOnSurface).padding(24)
    }.background(Color.nativeSurface.ignoresSafeArea()).navigationTitle("开源许可")
  }
}

extension View {
  /// 原版 SCard settings 变体：surface-panel、无边框，medium 内边距 16×12，small 12×8
  /// @param radius - 圆角，默认 lg 8
  /// @param small - 是否为 small 尺寸
  fileprivate func nativeAboutCard(radius: CGFloat = 8, small: Bool = false) -> some View {
    padding(.horizontal, small ? 12 : 16).padding(.vertical, small ? 8 : 12)
      .background(Color.nativeSurfacePanel, in: RoundedRectangle(cornerRadius: radius))
      .contentShape(RoundedRectangle(cornerRadius: radius))
  }
}
