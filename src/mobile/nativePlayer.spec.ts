import { beforeEach, expect, it, vi } from "vitest";
import type { PlayerApi, PlayerStatus } from "@shared/types/player";
import { createNativePlayer } from "./nativePlayer";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  listener: vi.fn(),
  sync: vi.fn(),
  track: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocks.invoke,
  addPluginListener: mocks.listener,
}));
vi.mock("./lyricPip", () => ({ mobileLyricPip: { sync: mocks.sync } }));
vi.mock("./mediaSession", () => ({
  mobileMediaSession: { setTrack: mocks.track, setPosition: vi.fn() },
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
  expect(mocks.listener).toHaveBeenCalledTimes(6);
  expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|load", {
    source: "https://example.com/song.mp3",
    autoPlay: false,
  });
  expect(mocks.sync).toHaveBeenCalledWith(status);
  await player.seek(10000);
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|control", {
    action: "seek",
    position: 10000,
  });
});
