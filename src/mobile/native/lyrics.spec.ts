import { beforeEach, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";
import { loadNativeLyrics } from "./lyrics";
const mocks = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock("../providers", () => ({ mobileProviders: { call: mocks.call } }));
beforeEach(() => vi.resetAllMocks());
const track = { id: "1", title: "测试", duration: 120500, source: "netease" } as Track;
it("YRC 保留逐字毫秒和对应翻译", async () => {
  mocks.call.mockResolvedValue({
    ok: true,
    body: {
      yrc: { lyric: "[1000,1000](1000,400,0)你(1400,600,0)好" },
      ytlrc: { lyric: "[00:01.00]Hello" },
    },
  });
  const result = await loadNativeLyrics(track);
  expect(result.lines[0]).toMatchObject({
    timeMs: 1000,
    endMs: 2000,
    text: "你好",
    translation: "Hello",
    words: [
      { text: "你", startMs: 1000, endMs: 1400 },
      { text: "好", startMs: 1400, endMs: 2000 },
    ],
  });
});
it("普通 LRC 不伪造逐字时间", async () => {
  mocks.call.mockResolvedValue({ ok: true, body: { lrc: { lyric: "[00:02.50]测试歌词" } } });
  const result = await loadNativeLyrics(track);
  expect(result.lines[0]).toMatchObject({ timeMs: 2500, text: "测试歌词" });
  expect(result.lines[0].words).toHaveLength(1);
});
it("QQ 使用数字 ID，酷狗只在接口边界把毫秒转换为秒", async () => {
  mocks.call.mockResolvedValue({ ok: true, body: { lrc: "[00:01]歌词" } });
  await loadNativeLyrics({ ...track, source: "qqmusic", extId: "123" });
  expect(mocks.call).toHaveBeenLastCalledWith("qqmusic", "lyric", { id: "123" });
  await loadNativeLyrics({ ...track, source: "kugou" });
  expect(mocks.call).toHaveBeenLastCalledWith("kugou", "lyric", {
    hash: "1",
    name: "测试",
    duration: 121,
  });
});
it("超大歌词和失败响应不进入渲染", async () => {
  mocks.call.mockResolvedValue({ ok: true, body: { lrc: { lyric: "x".repeat(2_000_001) } } });
  await expect(loadNativeLyrics(track)).rejects.toThrow("大小限制");
  mocks.call.mockResolvedValue({ ok: false, error: "失败" });
  await expect(loadNativeLyrics(track)).rejects.toThrow("失败");
});
