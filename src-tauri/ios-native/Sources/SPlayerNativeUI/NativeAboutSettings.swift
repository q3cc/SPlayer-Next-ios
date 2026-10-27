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
    Form {
      Section("关于软件") {
        HStack(spacing: 12) {
          NativeLogo().frame(width: 34, height: 34)
          Text("SPlayer-Next-ios").font(.custom("Poppins-Medium", size: 18))
          Text("v" + NativeBuildInfo.version).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.tint.opacity(0.14), in: Capsule())
            .foregroundStyle(.tint)
          Spacer(minLength: 8)
          Button {
            Task { await checkUpdate() }
          } label: {
            HStack(spacing: 6) {
              if checking { ProgressView().controlSize(.small) } else {
                Image(systemName: "arrow.clockwise")
              }
              Text(release != nil ? "发现新版本" : checking ? "检查中" : "检查更新")
            }
          }.buttonStyle(.bordered).disabled(checking)
            .accessibilityIdentifier("native.about.checkUpdate")
        }.padding(.vertical, 4)
      }
      Section("特别致谢") {
        ForEach(Self.dependencies, id: \.0) { name, description, url in
          linkRow(url) {
            VStack(alignment: .leading, spacing: 2) {
              Text(name).font(.system(size: 15, weight: .medium))
              Text(description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
      }
      Section("开发人员") {
        developers(
          "iOS 版本贡献者", iosDevelopers, expanded: $allIos, iosVersion: true,
          identifier: "native.about.iosContributors")
        if !originalDevelopers.isEmpty {
          developers(
            "原版项目贡献者", originalDevelopers, expanded: $allOriginal, iosVersion: false,
            identifier: "native.about.originalContributors")
        }
      }
      Section("社区与资讯") {
        linkRow(NativeGitHub.repoURL.absoluteString) {
          Label("SPlayer-Next-ios", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        linkRow(NativeGitHub.repoURL.absoluteString) {
          Label("官方网站", systemImage: "dot.radiowaves.up.forward")
        }
        NavigationLink {
          NativeLicensesView().nativeSettingsPage()
        } label: {
          Label("开源许可", systemImage: "doc.text")
        }
      }
      Section {
        ForEach(environment, id: \.0) { label, value, url in
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            if let url {
              Button {
                openURL(url)
              } label: {
                HStack(spacing: 4) {
                  Text(value)
                  Image(systemName: "arrow.up.right").font(.caption2)
                }
              }.buttonStyle(.borderless)
            } else {
              Text(value).textSelection(.enabled)
            }
          }.font(.system(size: 14))
        }
      } header: {
        HStack {
          Text("环境信息")
          Spacer()
          Button {
            copyEnvironment()
          } label: {
            Image(systemName: "doc.on.doc")
          }.buttonStyle(.borderless).accessibilityLabel("复制环境信息")
        }
      }
    }
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

  private func linkRow<Label: View>(_ url: String, @ViewBuilder label: () -> Label) -> some View {
    Button {
      if let url = URL(string: url) { openURL(url) }
    } label: {
      HStack {
        label()
        Spacer()
        Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain)
  }

  /// 贡献者网格：默认展示前 6 位，其余折叠
  private func developers(
    _ title: String, _ items: [NativeContributor], expanded: Binding<Bool>, iosVersion: Bool,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10
      ) {
        ForEach(expanded.wrappedValue ? items : Array(items.prefix(6))) { dev in
          Button {
            if let url = URL(string: dev.htmlUrl) { openURL(url) }
          } label: {
            HStack(spacing: 10) {
              NativeArtwork(cover: dev.avatar.isEmpty ? nil : dev.avatar, radius: 18)
                .frame(width: 36, height: 36)
              VStack(alignment: .leading, spacing: 2) {
                Text(dev.login).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(role(dev.login, iosVersion: iosVersion)).font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
            }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
              .contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }.accessibilityIdentifier(identifier)
      if items.count > 6 {
        Button {
          expanded.wrappedValue.toggle()
        } label: {
          Label(
            expanded.wrappedValue ? "收起" : "更多贡献者",
            systemImage: expanded.wrappedValue ? "chevron.up" : "chevron.down")
        }.buttonStyle(.borderless).font(.footnote)
      }
    }.padding(.vertical, 4)
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
          Text(name).font(.headline)
          if let url = Bundle.module.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
          {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
        }
      }.padding(24)
    }.navigationTitle("开源许可")
  }
}
