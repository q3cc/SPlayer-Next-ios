import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

const native = readFileSync(
  `${process.cwd()}/src-tauri/plugins/native-audio/ios/Sources/NativeAudioPlugin.swift`,
  "utf8",
);
const picker = native.split("@objc func airplay(")[1].split("override func load(")[0];
const routes = readFileSync(
  "src-tauri/plugins/native-audio/ios/Sources/AirPlayRouteController.swift",
  "utf8",
);

it("音乐会话配置长音频路由并声明音频媒体类型", () => {
  expect(native).toContain("setCategory(.playback, mode: .default, policy: .longFormAudio)");
  expect(native).toContain("MPNowPlayingInfoMediaType.audio.rawValue");
});
it("原生路由控件直接接收触摸，不查找内部按钮或模拟点击", () => {
  expect(routes).toContain("AVRoutePickerView(frame:");
  expect(routes).toContain("host.addSubview(entry.picker)");
  expect(routes).toContain("prioritizesVideoDevices = false");
  for (const source of [picker, routes]) {
    expect(source).not.toContain("sendActions");
    expect(source).not.toContain("as? UIButton");
    expect(source).not.toContain("layer.opacity = 0");
    expect(source).not.toContain("isUserInteractionEnabled = false");
    expect(source).not.toContain("MPVolumeView(frame:");
  }
});
it("生命周期交给原生路由控制器，WebView 隐藏时不直接移除呈现者", () => {
  const visibility = native
    .split("@objc func visibility(")[1]
    .split("private func updatePosition(")[0];
  expect(visibility).toContain("airPlayRoutes.setVisible(request.visible)");
  expect(visibility).not.toContain("removeFromSuperview");
  expect(routes).toContain("routePickerViewWillBeginPresentingRoutes");
  expect(routes).toContain("routePickerViewDidEndPresentingRoutes");
});
it("真实呈现回调同步歌曲信息并记录诊断，不另起播放器", () => {
  const presenting = native.split("routes.willPresent =")[1].split("return routes")[0];
  expect(presenting).toContain("self?.updatePosition()");
  expect(presenting).toContain('reportAirPlaySession("presenting")');
  expect(presenting).toContain('reportAirPlaySession("dismissed")');
  expect(picker).not.toContain("AudioPlayer()");
  expect(picker).not.toContain(".play(");
  expect(routes).not.toContain("AVPlayer(");
});
it("启动阶段不再异步覆盖播放器的音频会话", () => {
  const startup = readFileSync("src-tauri/src/lib.rs", "utf8");
  expect(startup).not.toContain("configure_ios_audio_session");
  expect(startup).not.toContain("setCategory_error");
});
