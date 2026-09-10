import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

const native = readFileSync(
  `${process.cwd()}/src-tauri/plugins/native-audio/ios/Sources/NativeAudioPlugin.swift`,
  "utf8",
);
const picker = native.split("@objc func airplay(")[1].split("override func load(")[0];

it("音乐会话配置长音频路由并声明音频媒体类型", () => {
  expect(native).toContain("setCategory(.playback, mode: .default, policy: .longFormAudio)");
  expect(native).toContain("MPNowPlayingInfoMediaType.audio.rawValue");
});
it("原生按钮仅作为锚点，不绘制图标，也不拦截前端点击", () => {
  expect(picker).toContain("picker.layer.opacity = 0");
  expect(picker).toContain("picker.isUserInteractionEnabled = false");
  expect(picker).not.toContain("picker.isHidden = true");
  expect(picker).toContain("routePickerView.removeFromSuperview()");
});
it("打开面板之前同步歌曲信息，不另起播放器", () => {
  expect(picker.indexOf("self.updatePosition()")).toBeLessThan(
    picker.indexOf("button.sendActions(for: .touchUpInside)"),
  );
  expect(picker).not.toContain("AudioPlayer()");
  expect(picker).not.toContain(".play(");
});
