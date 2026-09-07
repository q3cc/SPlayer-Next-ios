import { beforeEach, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";

const mocks = vi.hoisted(() => ({
  search: vi.fn(),
  netease: vi.fn(),
  qqmusic: vi.fn(),
  kugou: vi.fn(),
}));
vi.mock("../providers", () => ({ mobileProviders: {} }));
vi.mock("@/apis/search", () => ({ searchSongs: mocks.search }));
vi.mock("@/apis/song/netease", () => ({ resolveNeteaseUrl: mocks.netease }));
vi.mock("@/apis/song/qqmusic", () => ({ resolveQQMusicUrl: mocks.qqmusic }));
vi.mock("@/apis/song/kugou", () => ({ resolveKugouUrl: mocks.kugou }));
import { run } from "./background";

const song = (source: Track["source"], title = "晴天", artist = "周杰伦"): Track => ({
  source,
  id: source,
  title,
  artists: [{ name: artist }],
  duration: 240000,
});
const request = {
  action: "search",
  query: "晴天",
  artist: "周杰伦",
  source: "netease",
  scope: "online",
  library: [],
  quality: "hq",
  allowTrial: false,
} as const;
const options = { ...request, library: [] as Track[] };
beforeEach(() => {
  vi.resetAllMocks();
  mocks.search.mockImplementation(async (source) => ({ items: [song(source)] }));
});

it("并行搜索三个平台，网易云没有结果或失败不影响 QQ 和酷狗，VIP 优先", async () => {
  mocks.search.mockImplementation(async (source) => {
    if (source === "netease") throw new Error("不可用");
    return { items: [song(source)] };
  });
  expect(await run({ ...options, vipSources: ["kugou"] })).toEqual({
    tracks: [song("kugou"), song("qqmusic")],
  });
  expect(new Set(mocks.search.mock.calls.map(([source]) => source))).toEqual(
    new Set(["netease", "qqmusic", "kugou"]),
  );
});

it("有 VIP 的翻唱或现场版不能排到准确匹配的原曲前面", async () => {
  mocks.search.mockImplementation(async (source) => ({
    items:
      source === "qqmusic"
        ? [song(source, "晴天", "翻唱歌手"), song(source, "晴天（Live）")]
        : [song(source)],
  }));
  const result = (await run({ ...options, vipSources: ["qqmusic"] })) as { tracks: Track[] };
  expect(result.tracks[0]).toEqual(song("netease"));
  expect(result.tracks.some((track) => track.artists[0].name === "翻唱歌手")).toBe(false);
});

it("选中平台只有试听时优先换到 VIP 平台完整版，并返回实际歌曲身份用于歌词", async () => {
  mocks.netease.mockResolvedValue({ available: true, url: "trial", isTrial: true });
  mocks.qqmusic.mockResolvedValue({ available: true, url: "full", isTrial: false });
  expect(
    await run({
      ...options,
      action: "resolve",
      track: song("netease"),
      vipSources: ["qqmusic"],
      allowTrial: true,
    }),
  ).toEqual({ url: "full", isTrial: false, track: song("qqmusic") });
});

it("换源搜索失败时仍可按用户授权播放已获取的试听", async () => {
  mocks.netease.mockResolvedValue({ available: true, url: "trial", isTrial: true });
  mocks.search.mockRejectedValue(new Error("断网"));
  expect(
    await run({ ...options, action: "resolve", track: song("netease"), allowTrial: true }),
  ).toEqual({ url: "trial", isTrial: true, track: song("netease") });
  await expect(run({ ...options, action: "resolve", track: song("netease") })).rejects.toThrow(
    "允许试听",
  );
});

it("仅本地搜索不联网，所有在线平台失败时明确报错", async () => {
  expect(await run({ ...options, scope: "local" })).toEqual({ tracks: [] });
  expect(mocks.search).not.toHaveBeenCalled();
  mocks.search.mockRejectedValue(new Error("断网"));
  await expect(run(options)).rejects.toThrow("三个音乐平台搜索均失败");
});

it("明确歌手时保留歌名中的‘的’，口语查询未命中再拆连接词", async () => {
  mocks.search.mockResolvedValue({ items: [song("qqmusic", "特别的人", "方大同")] });
  await run({ ...options, query: "特别的人", artist: "方大同" });
  expect(mocks.search.mock.calls.every(([, keyword]) => keyword === "特别的人 方大同")).toBe(true);
  mocks.search.mockClear();
  mocks.search.mockImplementation(async (source, keyword) => ({
    items: keyword === "方大同 特别的人" ? [song(source, "特别的人", "方大同")] : [],
  }));
  const result = (await run({ ...options, query: "方大同的特别的人", artist: "" })) as {
    tracks: Track[];
  };
  expect(result.tracks).toHaveLength(3);
  expect(mocks.search).toHaveBeenCalledTimes(6);
});
