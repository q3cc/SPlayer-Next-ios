import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";
import type { PluginInfo } from "@shared/types/plugin";
import { resolveTrackSource } from "./audioSource";

const { resolve, settings, lookup, pluginList, resolvePlugin, priority } = vi.hoisted(() => ({
  resolve: vi.fn(),
  lookup: vi.fn(),
  pluginList: [] as PluginInfo[],
  resolvePlugin: vi.fn(),
  priority: vi.fn(),
  settings: {
    player: { songLevel: "hq", allowTrialPlay: true },
    system: { cache: { songCache: { enabled: true } } },
  },
}));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => settings }));
vi.mock("@/stores/plugins", () => ({ usePluginsStore: () => ({ list: pluginList }) }));
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
  pluginList.length = 0;
  resolvePlugin.mockReset();
  priority.mockResolvedValue([]);
  lookup.mockResolvedValue(null);
  settings.player.allowTrialPlay = true;
  Object.defineProperty(window, "api", {
    configurable: true,
    value: {
      cache: { song: { lookup, fetch: vi.fn() } },
      plugins: { resolveUrl: resolvePlugin },
      config: { get: priority },
    },
  });
});

describe("多音源顺序尝试", () => {
  beforeEach(() => {
    for (const id of ["first", "second", "disabled"]) {
      pluginList.push({
        manifest: {
          id,
          name: id,
          version: "1",
          grant: ["network"],
          apiLevel: 1,
          hash: id,
          installedAt: 0,
          fileName: id + ".js",
        },
        enabled: id !== "disabled",
        status: {
          state: "ready",
          sources: { kg: { name: "酷狗", actions: ["musicUrl"], qualities: ["hq"] } },
        },
      } as PluginInfo);
    }
    resolve.mockResolvedValue({ available: true, url: "https://example.com/trial", isTrial: true });
  });

  it("按已保存优先级尝试，失败后继续且跳过禁用音源", async () => {
    priority.mockResolvedValue(["disabled", "second", "first"]);
    resolvePlugin.mockRejectedValueOnce(new Error("第三方服务不可用"));
    resolvePlugin.mockResolvedValueOnce({ url: "https://example.com/plugin" });
    const result = await resolveTrackSource(track, { silent: true });
    expect(result?.provider).toBe("plugin");
    expect(resolvePlugin.mock.calls.map(([args]) => args.pluginId)).toEqual(["second", "first"]);
  });

  it("官方完整音源优先，不请求插件", async () => {
    resolve.mockResolvedValue({ available: true, url: "https://example.com/full", isTrial: false });
    expect((await resolveTrackSource(track, { silent: true }))?.provider).toBe("official");
    expect(resolvePlugin).not.toHaveBeenCalled();
  });

  it("全部插件失败后仅在允许时播放试听", async () => {
    resolvePlugin.mockRejectedValue(new Error("音源不支持所选音质"));
    expect((await resolveTrackSource(track, { silent: true }))?.provider).toBe("trial");
    settings.player.allowTrialPlay = false;
    expect(await resolveTrackSource(track, { silent: true })).toBeNull();
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

  it("已下载歌曲在关闭临时歌曲缓存时直接播放本地文件", async () => {
    settings.system.cache.songCache.enabled = false;
    window.api.download = {
      lookup: vi.fn().mockResolvedValue("file:///Documents/Downloads/song.flac"),
    } as never;
    const result = await resolveTrackSource(track, { silent: true });
    expect(result?.source).toBe("file:///Documents/Downloads/song.flac");
    expect(result?.provider).toBe("download");
    expect(resolve).not.toHaveBeenCalled();
    settings.system.cache.songCache.enabled = true;
  });
});
