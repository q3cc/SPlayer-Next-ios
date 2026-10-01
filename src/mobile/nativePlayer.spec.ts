import { beforeEach, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import type { PlayerApi, PlayerStatus } from "@shared/types/player";
import { createNativePlayer } from "./nativePlayer";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  listener: vi.fn(),
  sync: vi.fn(),
  track: vi.fn(),
  download: vi.fn(),
  like: vi.fn(),
}));
vi.mock("./downloadMedia", () => ({
  findDownloadMedia: mocks.download,
  readDownloadMedia: mocks.download,
  downloadFileUrl: (path: string) => `file://${path}`,
}));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocks.invoke,
  addPluginListener: mocks.listener,
  convertFileSrc: (path: string) => `asset://${path}`,
}));
vi.mock("./lyricPip", () => ({ mobileLyricPip: { sync: mocks.sync } }));
vi.mock("./mediaSession", () => ({
  mobileMediaSession: { setTrack: mocks.track, setPosition: vi.fn(), setLikeState: mocks.like },
}));
const status: PlayerStatus = {
  state: "playing",
  position: 1500,
  duration: 200000,
  volume: 1,
  speed: 1,
  isFinished: false,
};

beforeEach(() => {
  mocks.invoke.mockReset().mockResolvedValue(status);
  mocks.listener.mockReset().mockResolvedValue({ unregister: vi.fn() });
  mocks.download.mockReset().mockResolvedValue(null);
});

it("系统音量命令已注册且默认向移动端开放", () => {
  const build = readFileSync("src-tauri/plugins/native-audio/build.rs", "utf8");
  const permissions = readFileSync(
    "src-tauri/plugins/native-audio/permissions/default.toml",
    "utf8",
  );
  expect(build).toContain('"system_volume"');
  expect(permissions).toContain('"allow-system-volume"');
});

it("音量读取与用户调节走系统音量接口，不修改音效增益", async () => {
  const player = createNativePlayer({} as PlayerApi);
  mocks.invoke.mockResolvedValue({ volume: 0.42 });
  expect(await player.getVolume()).toEqual({ success: true, data: 0.42 });
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|system_volume", {});
  expect((await player.setVolume(0.6)).success).toBe(true);
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|system_volume", {
    value: 0.6,
  });
  expect(
    mocks.invoke.mock.calls.some(([command]) => command === "plugin:native-audio|configure"),
  ).toBe(false);
});

it("实体音量键的变化单独通知 UI，不覆盖 Siri 的播放状态", async () => {
  const player = createNativePlayer({} as PlayerApi);
  const listener = vi.fn();
  window.addEventListener("splayer:system-volume", listener);
  const events = vi.fn();
  player.onEvent(events);
  await vi.waitFor(() =>
    expect(mocks.listener.mock.calls.some(([, event]) => event === "systemVolume")).toBe(true),
  );
  const callback = mocks.listener.mock.calls.find(([, event]) => event === "systemVolume")![2];
  callback({ volume: 0.35 });
  expect(listener).toHaveBeenCalledWith(expect.objectContaining({ detail: 0.35 }));
  expect(events).not.toHaveBeenCalled();
  window.removeEventListener("splayer:system-volume", listener);
});

it("均衡器、前级与升降调调用原生节点，不调用 WebView 占位实现", async () => {
  const fallback = { setEqualizerBands: vi.fn() } as unknown as PlayerApi;
  const player = createNativePlayer(fallback);
  const bands = [0, 0, 0, 0, 0, 6, 0, 0, 0, 0];
  await Promise.all([
    player.setEqualizerBands(bands),
    player.setPreampGain(-3),
    player.setEqualizerEnabled(true),
    player.setPitch(2),
    player.setSpeed(1.5),
  ]);
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|configure",
    expect.objectContaining({ bands, preamp: -3, enabled: true, pitch: 2, speed: 1.5 }),
  );
  expect(fallback.setEqualizerBands).not.toHaveBeenCalled();
});

it("原生失败不能返回设置成功，也不覆盖上次有效音效", async () => {
  const player = createNativePlayer({} as PlayerApi);
  mocks.invoke.mockRejectedValueOnce(new Error("invalid bands"));
  expect((await player.setEqualizerBands([999])).success).toBe(false);
  await player.setPreampGain(-2);
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|configure",
    expect.objectContaining({ bands: Array(10).fill(0), preamp: -2 }),
  );
});

it("加载前安装原生事件，返回真实进度并同步歌词小窗", async () => {
  const player = createNativePlayer({} as PlayerApi);
  expect((await player.load("https://example.com/song.mp3", { autoPlay: false })).success).toBe(
    true,
  );
  expect(mocks.listener).toHaveBeenCalledTimes(8);
  expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|load", {
    source: "https://example.com/song.mp3",
    autoPlay: false,
    trackId: null,
  });
  expect(mocks.sync).toHaveBeenCalledWith(status);
  await player.seek(10000);
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|control", {
    action: "seek",
    position: 10000,
  });
});

it("加载时将歌曲身份与音源一起下发，避免后台把进度记到另一首歌", async () => {
  const player = createNativePlayer({} as PlayerApi);
  await player.load("https://example.com/song.mp3", {
    meta: { source: "netease", id: "resume", title: "断点测试", artists: [], duration: 200000 },
  });
  expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|load", {
    source: "https://example.com/song.mp3",
    autoPlay: true,
    trackId: "netease:resume",
  });
});

it("断网播放下载文件时向原生卡片传本地封面并返回本地歌词", async () => {
  const media = {
    audioPath: "/Documents/Downloads/song.flac",
    coverPath: "/Documents/Downloads/song.flac.cover.jpg",
    externalLyrics: [{ format: "ttml", path: "/Documents/Downloads/song.flac.ttml" }],
  };
  mocks.download.mockResolvedValue(media);
  const player = createNativePlayer({} as PlayerApi);
  const result = await player.load("file:///Documents/Downloads/song.flac", {
    meta: {
      source: "netease",
      id: "offline",
      title: "离线歌曲",
      artists: [],
      duration: 200000,
      cover: "https://example.com/remote.jpg",
    },
  });
  expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|load", {
    source: "file:///Documents/Downloads/song.flac",
    autoPlay: true,
    trackId: "netease:offline",
  });
  expect(mocks.track).toHaveBeenLastCalledWith(
    expect.objectContaining({ coverOriginal: "file:///Documents/Downloads/song.flac.cover.jpg" }),
  );
  expect(result.data?.detail).toMatchObject({
    downloaded: true,
    externalLyrics: media.externalLyrics,
  });
});

it("安卓系统收藏操作进入播放器事件并同步按钮状态", async () => {
  const player = createNativePlayer({} as PlayerApi);
  const events = vi.fn();
  player.onEvent(events);
  await vi.waitFor(() =>
    expect(mocks.listener.mock.calls.some(([, event]) => event === "action")).toBe(true),
  );
  const callback = mocks.listener.mock.calls.find(([, event]) => event === "action")![2];
  callback({ type: "toggleLike" });
  expect(events).toHaveBeenCalledWith({ type: "toggleLike" });
  player.syncLikeState(true, true);
  expect(mocks.like).toHaveBeenCalledWith(true, true);
});

it("安卓把旧的网易云 HTTP 音源升级为 HTTPS，不改动签名参数", async () => {
  const player = createNativePlayer({} as PlayerApi);
  await player.load("http://m10.music.126.net/song.mp3?token=a%2Fb");
  expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|load", {
    source: "https://m10.music.126.net/song.mp3?token=a%2Fb",
    autoPlay: true,
    trackId: null,
  });
});

it("原生加载等实际播放态再完成，等待数据回调不能提前暂停或取消超时", () => {
  const swift = readFileSync(
    "src-tauri/plugins/native-audio/ios/Sources/NativeAudioPlugin.swift",
    "utf8",
  );
  const started = swift
    .split("func audioPlayerDidStartPlaying(")[1]
    .split("func audioPlayerStateChanged(")[0];
  expect(started).not.toContain("pending.resolve");
  expect(started).not.toContain("player.pause()");
  expect(started).not.toContain("loadTimeout?.cancel()");
  const changed = swift
    .split("func audioPlayerStateChanged(")[1]
    .split("func audioPlayerDidFinishPlaying(")[0];
  expect(changed).toContain(
    "newState == .playing, player.state == .playing, let pending = self.pendingLoad",
  );
  expect(changed).toContain("pending.resolve(self.snapshot())");
});

it("后台定期存档、暂停和退后台保存进度均不依赖 Siri 开关", () => {
  const swift = readFileSync(
    "src-tauri/plugins/native-audio/ios/Sources/NativeAudioPlugin.swift",
    "utf8",
  );
  expect(swift).not.toContain("if SiriService.shared.enabled { SiriService.shared.checkpoint()");
  const visibility = swift
    .split("@objc func visibility(")[1]
    .split("private func updatePosition(")[0];
  expect(visibility).toContain("if !request.visible");
  expect(visibility).toContain("SiriService.shared.checkpoint()");
  const timer = swift
    .split("timer = Timer.scheduledTimer")[1]
    .split("func audioPlayerDidStartPlaying")[0];
  expect(timer).toContain('if self.visible { self.trigger("position", data: self.snapshot()) }');
  expect(timer).toContain("SiriService.shared.checkpoint()");
});

it("淡入淡出、标准化与频谱合并参数，失败不伪造成功状态", async () => {
  const player = createNativePlayer({} as PlayerApi);
  await Promise.all([
    player.setFadeDuration(300),
    player.setNormalizationEnabled(true),
    player.setFftEnabled(true),
  ]);
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|audio_processing", {
    fadeDuration: 300,
    normalization: true,
    fftEnabled: true,
  });
  mocks.invoke.mockRejectedValueOnce(new Error("permission denied"));
  expect((await player.setFadeDuration(500)).success).toBe(false);
  expect(await player.getFadeDuration()).toEqual({ success: true, data: 300 });
});
it("只有开启频谱且页面可见时转发真实频谱", async () => {
  const player = createNativePlayer({} as PlayerApi);
  const event = vi.fn();
  player.onEvent(event);
  await player.setFftEnabled(true);
  const callback = mocks.listener.mock.calls.find(([, name]) => name === "fftData")![2];
  const data = { ldata: [0.4], rdata: [0.6] };
  callback(data);
  expect(event).toHaveBeenLastCalledWith({ type: "fftData", data });
  await player.setFftEnabled(false);
  event.mockClear();
  callback(data);
  expect(event).not.toHaveBeenCalled();
});
