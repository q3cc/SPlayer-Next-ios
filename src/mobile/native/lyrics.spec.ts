import { beforeEach, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";
import { exportNativeLyrics, loadNativeLyrics, parseNativeLyrics } from "./lyrics";
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
  expect(result.format).toBe("yrc");
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
  // 原版标签显示真实格式，普通 LRC 不能标成逐字
  expect(result.format).toBe("lrc");
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

it("原文与罗马音保留到原生显示和复制接口", async () => {
  mocks.call.mockResolvedValue({
    ok: true,
    body: { lrc: { lyric: "[00:01.00]你好" }, romalrc: { lyric: "[00:01.00]ni hao" } },
  });
  const result = await loadNativeLyrics(track);
  expect(result.raw).toBe("[00:01.00]你好");
  expect(result.lines[0].romanization).toBe("ni hao");
});

it("导入 TTML 保留真实逐字时间", () => {
  const result = parseNativeLyrics({
    content:
      '<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s" end="3s"><span begin="1s" end="2s">你</span><span begin="2s" end="3s">好</span></p></div></body></tt>',
  });
  expect(result.lines[0].words.map((word) => word.startMs)).toEqual([1000, 2000]);
  expect(result.lines[0].endMs).toBe(3000);
  expect(result.format).toBe("ttml");
});

it("没有 DOMParser 的原生运行时解析 TTML 与浏览器结果一致", () => {
  const content = [
    '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"',
    ' xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word">',
    '<head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/>',
    "</metadata></head>",
    '<body dur="00:10.000"><div begin="00:01.000" end="00:09.000">',
    '<p begin="00:01.000" end="00:03.000" ttm:agent="v1" itunes:key="L1">',
    '<span begin="00:01.000" end="00:01.500">Hello</span> <span begin="00:01.600" end="00:03.000">world &amp; you</span>',
    '<span ttm:role="x-translation" xml:lang="zh-CN">你好 世界</span>',
    '<span ttm:role="x-bg"><span begin="00:02.000" end="00:02.500">(oh)</span></span></p>',
    '<p begin="00:04.000" end="00:06.000" ttm:agent="v2">',
    '<span begin="00:04.000" end="00:05.000">晚</span><span begin="00:05.000" end="00:06.000">安</span>',
    '<span ttm:role="x-roman">wan an</span></p>',
    "</div></body></tt>",
  ].join("");
  const browser = parseNativeLyrics({ content });
  vi.stubGlobal("DOMParser", undefined);
  try {
    const native = parseNativeLyrics({ content });
    expect(native).toEqual(browser);
    expect(native.lines.length).toBeGreaterThan(1);
    expect(native.lines[0].words.length).toBeGreaterThan(1);
    expect(() => parseNativeLyrics({ content: "<tt><body><p>" })).toThrow();
  } finally {
    vi.unstubAllGlobals();
  }
});

it("按行标注语言，供原生分语言字体使用", () => {
  const chinese = parseNativeLyrics({ content: "[00:01.00]你好世界\n[00:02.00]Hello world" });
  expect(chinese.lines.map((line) => line.language)).toEqual(["zh-CN", "und-Latn"]);
  // 含假名的歌曲中，纯汉字行按整首歌判定为日语
  const japanese = parseNativeLyrics({
    content: "[00:01.00]夜空\n[00:02.00]こんにちは\n[00:03.00]안녕하세요",
  });
  expect(japanese.lines.map((line) => line.language)).toEqual(["ja", "ja", "ko"]);
});

it("下载导出 TTML 与所选 LRC 格式", async () => {
  mocks.call.mockResolvedValue({
    ok: true,
    body: {
      yrc: { lyric: "[1000,1000](1000,400,0)你(1400,600,0)好" },
      ytlrc: { lyric: "[00:01.00]Hello" },
    },
  });
  const enhanced = await exportNativeLyrics(track, "enhanced-lrc");
  expect(enhanced.ttml).toContain("<tt");
  expect(enhanced.ttml).toContain("Hello");
  expect(enhanced.lrc).toContain("<00:01.40>好");
  const plain = await exportNativeLyrics(track, "lrc");
  expect(plain.lrc).toContain("[00:01.00]你好");
  mocks.call.mockResolvedValue({ ok: true, body: {} });
  expect(await exportNativeLyrics(track, "lrc")).toEqual({ ttml: "", lrc: "" });
});
