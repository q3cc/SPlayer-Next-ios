import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";
import { resolveTrackSource } from "./audioSource";

const { resolve, settings, lookup } = vi.hoisted(() => ({
  resolve: vi.fn(),
  lookup: vi.fn(),
  settings: {
    player: { songLevel: "hq", allowTrialPlay: true },
    system: { cache: { songCache: { enabled: true } } },
  },
}));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => settings }));
vi.mock("@/stores/plugins", () => ({ usePluginsStore: () => ({ list: [] }) }));
vi.mock("@/stores/streaming", () => ({ useStreamingStore: vi.fn() }));
vi.mock("@/stores/user", () => ({ useUserStore: vi.fn() }));
vi.mock("@/apis/song/kugou", () => ({ resolveKugouUrl: resolve }));
vi.mock("@/apis/song/netease", () => ({ resolveNeteaseUrl: vi.fn() }));
vi.mock("@/apis/song/qqmusic", () => ({ resolveQQMusicUrl: vi.fn() }));
vi.mock("@/utils/errors", () => ({ handleError: vi.fn() }));

const track = {
  id: "hash",
  source: "kugou",
  title: "晴天",
  artists: [],
  duration: 240000,
} as Track;

beforeEach(() => {
  resolve.mockReset();
  lookup.mockResolvedValue(null);
  settings.player.allowTrialPlay = true;
  Object.defineProperty(window, "api", {
    configurable: true,
    value: { cache: { song: { lookup, fetch: vi.fn() } } },
  });
});

describe("酷狗试听进入播放器", () => {
  it("试听保留来源标记且不会写入完整歌曲缓存", async () => {
    resolve.mockResolvedValue({ available: true, url: "https://example.com/trial", isTrial: true });
    const result = await resolveTrackSource(track, { silent: true });
    expect(resolve).toHaveBeenCalledWith(track, "hq", true);
    expect(result?.provider).toBe("trial");
    expect(result?.cacheRequest).toBeUndefined();
  });

  it("完整歌曲仍支持缓存", async () => {
    resolve.mockResolvedValue({ available: true, url: "https://example.com/full", isTrial: false });
    const result = await resolveTrackSource(track, { silent: true });
    expect(result?.provider).toBe("official");
    expect(result?.cacheRequest).toBeTypeOf("function");
  });

  it("关闭允许试听时拒绝平台直接返回的试听", async () => {
    settings.player.allowTrialPlay = false;
    resolve.mockResolvedValue({ available: true, url: "https://example.com/trial", isTrial: true });
    expect(await resolveTrackSource(track, { silent: true })).toBeNull();
    expect(resolve).toHaveBeenCalledWith(track, "hq", false);
  });
});

describe("离线缓存音源", () => {
  it("缓存命中时不请求在线解析接口", async () => {
    lookup.mockResolvedValue("/cache/offline-songs/song.flac");
    resolve.mockRejectedValue(new Error("offline"));
    expect(await resolveTrackSource(track)).toEqual({
      source: "/cache/offline-songs/song.flac",
      fromCache: true,
      provider: "cache",
    });
    expect(resolve).not.toHaveBeenCalled();
    expect(lookup).toHaveBeenCalledWith("o:kugou:hash::hq");
  });
});
