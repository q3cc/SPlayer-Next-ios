import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NowPlayingSnapshot } from "@shared/types/nowPlaying";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn().mockResolvedValue(undefined),
  addListener: vi.fn(),
  error: vi.fn(),
  events: new Map<string, (event: { active?: boolean; playing?: boolean }) => void>(),
}));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocks.invoke,
  addPluginListener: mocks.addListener,
}));
vi.mock("@/composables/useToast", () => ({ toast: { error: mocks.error } }));

const value = {
  track: { id: "one", title: "歌曲", artists: [{ name: "歌手" }], duration: 60000 },
  lyric: [
    {
      startTime: 1000,
      endTime: 3000,
      words: [{ word: "第一句" }],
      translatedLyric: "翻译",
      isBG: false,
    },
    { startTime: 2000, endTime: 3000, words: [{ word: "和声" }], translatedLyric: "", isBG: true },
    { startTime: 5000, endTime: 6000, words: [{ word: "  " }], translatedLyric: "", isBG: false },
  ],
  lyricOffsetMs: 250,
  position: 1500,
  playing: true,
  state: "playing",
  speed: 1,
  sendTimestamp: 12345,
} as NowPlayingSnapshot;

beforeEach(() => {
  vi.resetModules();
  mocks.invoke.mockReset().mockResolvedValue(undefined);
  mocks.events.clear();
  mocks.addListener.mockImplementation(async (_plugin, event, callback) => {
    mocks.events.set(event, callback);
    return { unregister: vi.fn() };
  });
});

describe("歌词画中画", () => {
  it("复用解析结果和翻译，不发送背景行、空行及伪逐字数据", async () => {
    const { pipContent } = await import("./lyricPip");
    expect(pipContent(value)).toEqual({
      title: "歌曲",
      artist: "歌手",
      cover: "",
      offset: 250,
      style: {
        frameRate: 60,
        fontSize: 24,
        playedColor: { r: 254, g: 121, b: 113, a: 1 },
        unplayedColor: { r: 255, g: 255, b: 255, a: 1 },
      },
      lines: [
        {
          start: 1000,
          end: 3000,
          primary: 0,
          nextPreview: false,
          words: [],
          rows: ["第一句", "翻译"],
        },
      ],
    });
  });

  it("字号和颜色传给原生绘制，兼容 RGB 和 HEX 配置", async () => {
    const { pipContent } = await import("./lyricPip");
    expect(
      pipContent(value, {
        doubleLine: false,
        showTranslation: true,
        fontSize: 36,
        playedColor: "#00ff00",
        unplayedColor: "rgb(12, 34, 56)",
      }).style,
    ).toEqual({
      frameRate: 60,
      fontSize: 36,
      playedColor: { r: 0, g: 255, b: 0, a: 1 },
      unplayedColor: { r: 12, g: 34, b: 56, a: 1 },
    });
  });

  it("帧率配置下发到原生，旧配置默认 60，非法值回退", async () => {
    const { pipContent } = await import("./lyricPip");
    for (const pipFrameRate of [5, 10, 15, 20, 30, 60]) {
      expect(
        pipContent(value, { doubleLine: false, showTranslation: true, pipFrameRate }).style
          .frameRate,
      ).toBe(pipFrameRate);
    }
    for (const pipFrameRate of [0, -1, 120, Number.NaN]) {
      expect(
        pipContent(value, { doubleLine: false, showTranslation: true, pipFrameRate }).style
          .frameRate,
      ).toBe(60);
    }
  });

  it("设置预览不打开画中画，释放预览不停止播放", async () => {
    const { mobileLyricPip: pip } = await import("./lyricPip");
    pip.configure(async () => value, vi.fn());
    mocks.invoke.mockResolvedValue({ image: "data:image/png;base64,test" });
    expect(await pip.preview()).toBe("data:image/png;base64,test");
    expect(mocks.invoke).toHaveBeenCalledWith(
      "plugin:lyric-pip|preview",
      expect.objectContaining({ position: 1500, playing: true }),
    );
    await pip.releasePreview();
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:lyric-pip|discard");
    expect(
      mocks.invoke.mock.calls.some(
        ([command]) => command.endsWith("|start") || command.endsWith("|stop"),
      ),
    ).toBe(false);
  });

  it("保留真实逐字时间轴，单行双行使用同一套原始时间", async () => {
    const { pipContent } = await import("./lyricPip");
    const timed = {
      ...value,
      lyric: [
        {
          ...value.lyric[0],
          words: [
            { word: "你", startTime: 1000, endTime: 1500 },
            { word: "好", startTime: 1600, endTime: 2000 },
          ],
        },
      ],
    };
    for (const doubleLine of [false, true]) {
      expect(pipContent(timed, { doubleLine, showTranslation: true }).lines[0].words).toEqual([
        { text: "你", start: 1000, end: 1500 },
        { text: "好", start: 1600, end: 2000 },
      ]);
    }
  });

  it("默认单行，不附带歌名或下一句", async () => {
    const { pipContent } = await import("./lyricPip");
    const single = { ...value, lyric: [{ ...value.lyric[0], translatedLyric: "" }] };
    expect(pipContent(single).lines[0].rows).toEqual(["第一句"]);
  });

  it("双行使用下一句；末句不补空白", async () => {
    const { pipContent } = await import("./lyricPip");
    const first = { ...value.lyric[0], translatedLyric: "" };
    const two = {
      ...value,
      lyric: [
        first,
        { ...first, startTime: 4000, words: [{ word: "第二句", startTime: 4000, endTime: 5000 }] },
      ],
    };
    const lines = pipContent(two, { doubleLine: true, showTranslation: true }).lines;
    expect(lines[0].rows).toEqual(["第一句", "第二句"]);
    expect(lines[1].rows).toEqual(["第二句"]);
  });

  it("参考桌面端，当前句始终在上，下一句在下", async () => {
    const { pipContent } = await import("./lyricPip");
    const lyric = ["一", "二", "三", "四"].map((word, index) => ({
      ...value.lyric[0],
      startTime: index * 4000,
      endTime: index * 4000 + 3000,
      translatedLyric: "",
      words: [{ word, startTime: index * 4000, endTime: index * 4000 + 3000 }],
    }));
    const lines = pipContent(
      { ...value, lyric },
      { doubleLine: true, showTranslation: true },
    ).lines;
    expect(lines.map(({ rows, primary }) => ({ rows, primary }))).toEqual([
      { rows: ["一", "二"], primary: 0 },
      { rows: ["二", "三"], primary: 0 },
      { rows: ["三", "四"], primary: 0 },
      { rows: ["四"], primary: 0 },
    ]);
  });

  it("连续进度每秒最多同步一次，暂停和强制拖动立即同步", async () => {
    const { mobileLyricPip: pip } = await import("./lyricPip");
    pip.configure(async () => value, vi.fn());
    await pip.toggle();
    mocks.events.get("visibility")?.({ active: true });
    mocks.invoke.mockClear();
    const status = {
      state: "playing" as const,
      position: 0,
      duration: 60000,
      volume: 1,
      speed: 1,
      isFinished: false,
    };
    const now = vi.spyOn(Date, "now");
    for (let i = 0; i <= 10; i++) {
      now.mockReturnValue(i * 100);
      pip.sync({ ...status, position: i * 100 });
      await Promise.resolve();
    }
    expect(mocks.invoke).toHaveBeenCalledTimes(2);
    pip.sync({ ...status, position: 1000, state: "paused" });
    await Promise.resolve();
    expect(mocks.invoke).toHaveBeenCalledTimes(3);
    pip.sync({ ...status, position: 1100, state: "paused" }, true);
    await Promise.resolve();
    expect(mocks.invoke).toHaveBeenCalledTimes(4);
    now.mockRestore();
  });

  it("单双行默认值持久保存，重新读取后仍生效", async () => {
    localStorage.removeItem("splayer.mobile.settings");
    const { store } = await import("./shims/store");
    store.clear();
    expect(store.get("desktopLyric.doubleLine")).toBe(false);
    expect(store.get("desktopLyric.pipFrameRate")).toBe(60);
    store.set("desktopLyric.doubleLine", true);
    store.set("desktopLyric.pipFrameRate", 20);
    vi.resetModules();
    const { store: reloaded } = await import("./shims/store");
    expect(reloaded.get("desktopLyric.doubleLine")).toBe(true);
    expect(reloaded.get("desktopLyric.pipFrameRate")).toBe(20);
    reloaded.clear();
  });

  it("有音译和翻译时替代下一句，不混入第二句原文", async () => {
    const { pipContent } = await import("./lyricPip");
    const translated = {
      ...value,
      lyric: [
        { ...value.lyric[0], romanLyric: "dai ichi" },
        {
          ...value.lyric[0],
          startTime: 4000,
          words: [{ word: "第二句", startTime: 4000, endTime: 5000 }],
        },
      ],
    };
    expect(
      pipContent(translated, { doubleLine: true, showTranslation: true }).lines[0].rows,
    ).toEqual(["第一句", "dai ichi", "翻译"]);
    expect(
      pipContent(translated, { doubleLine: true, showTranslation: false }).lines[0].rows,
    ).toEqual(["第一句", "第二句"]);
  });

  it("只有音译也不显示下一句，空白音译不占一行", async () => {
    const { pipContent } = await import("./lyricPip");
    const first = { ...value.lyric[0], translatedLyric: "", romanLyric: "romaji" };
    expect(pipContent({ ...value, lyric: [first] }).lines[0].rows).toEqual(["第一句", "romaji"]);
    expect(pipContent({ ...value, lyric: [{ ...first, romanLyric: "  " }] }).lines[0].rows).toEqual(
      ["第一句"],
    );
  });

  it("关闭时不拉快照、不发送歌词和进度", async () => {
    const { mobileLyricPip: pip } = await import("./lyricPip");
    const snapshot = vi.fn().mockResolvedValue(value);
    pip.configure(snapshot, vi.fn());
    await pip.update();
    pip.sync({
      state: "playing",
      position: 1000,
      duration: 60000,
      speed: 1,
      volume: 1,
      isFinished: false,
    });
    expect(snapshot).not.toHaveBeenCalled();
    expect(mocks.invoke).not.toHaveBeenCalled();
  });

  it("启动前发送歌词和锚点，只根据系统回调更新开关，关闭不停止音乐", async () => {
    const { mobileLyricPip: pip } = await import("./lyricPip");
    const playback = vi.fn();
    const visibility = vi.fn();
    pip.configure(async () => value, playback);
    const off = pip.onVisibility(visibility);
    await pip.toggle();
    expect(mocks.invoke.mock.calls.map((args) => args[0])).toEqual([
      "plugin:lyric-pip|update",
      "plugin:lyric-pip|sync",
      "plugin:lyric-pip|start",
    ]);
    expect(await pip.isOpen()).toBe(false);
    mocks.events.get("visibility")?.({ active: true });
    expect(await pip.isOpen()).toBe(true);
    mocks.events.get("playback")?.({ playing: false });
    expect(playback).toHaveBeenCalledWith(false);
    playback.mockClear();
    await pip.toggle();
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:lyric-pip|stop");
    mocks.events.get("visibility")?.({ active: false });
    expect(playback).not.toHaveBeenCalled();
    expect(visibility).toHaveBeenLastCalledWith(false);
    off();
  });

  it("启动失败显示原因，不把开关伪装成已开启", async () => {
    const { mobileLyricPip: pip } = await import("./lyricPip");
    pip.configure(async () => value, vi.fn());
    mocks.invoke.mockImplementation(async (command) => {
      if (command.endsWith("|start")) throw new Error("设备不支持画中画");
    });
    await pip.toggle();
    expect(mocks.error).toHaveBeenCalledWith("设备不支持画中画");
    expect(await pip.isOpen()).toBe(false);
  });
});
