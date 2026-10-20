import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";

const indexedStorage = vi.hoisted(() => {
  const values = new Map<string, unknown>();
  return {
    values,
    getItem: vi.fn(async (key: string) => structuredClone(values.get(key) ?? null)),
    setItem: vi.fn(async (key: string, value: unknown) => {
      values.set(key, structuredClone(value));
      return value;
    }),
  };
});

vi.mock("localforage", () => ({
  default: { createInstance: () => indexedStorage },
}));
vi.mock("./library", () => ({ mobileLibrary: {} }));
const track: Track = {
  id: "1",
  source: "netease",
  title: "红豆",
  artists: [{ id: "artist-1", name: "方大同" }],
  album: { id: "album-1", name: "15" },
  duration: 240000,
  quality: { codec: "flac", sampleRate: 44100, channels: 2, bitsPerSample: 16, bitRate: 0 },
};

beforeEach(() => {
  const values = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    get length() {
      return values.size;
    },
    key: (index: number) => [...values.keys()][index] ?? null,
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => {
      values.set(key, value);
    },
    removeItem: (key: string) => {
      values.delete(key);
    },
    clear: () => values.clear(),
  } satisfies Storage);
  indexedStorage.values.clear();
  indexedStorage.getItem.mockClear();
  indexedStorage.setItem.mockClear();
  vi.resetModules();
});

afterEach(() => vi.unstubAllGlobals());

describe("移动端统计存储", () => {
  it("localStorage 配额耗尽时仍写入 IndexedDB 并可在重载后恢复", async () => {
    vi.spyOn(localStorage, "setItem").mockImplementation(() => {
      throw new DOMException("full", "QuotaExceededError");
    });
    const { mobileStats } = await import("./stats");
    expect(() =>
      mobileStats.recordPlay({ track, startedAt: Date.now(), listenedMs: 1000 }),
    ).not.toThrow();
    expect(() => mobileStats.recordFavorite({ track, action: "add" })).not.toThrow();
    expect(await mobileStats.getStatsSummary()).toMatchObject({
      uniqueTrackCount: 1,
      uniqueAlbumCount: 1,
      uniqueArtistCount: 1,
      codecs: [{ codec: "flac", count: 1 }],
      totalPlayCount: 1,
      totalListenedMs: 1000,
      weekFavoriteAdds: 1,
    });
    await vi.waitFor(() => {
      expect(indexedStorage.values.get("plays")).toHaveLength(1);
      expect(indexedStorage.values.get("favorites")).toHaveLength(1);
    });

    vi.resetModules();
    const { mobileStats: restoredStats } = await import("./stats");
    expect(await restoredStats.getStatsSummary()).toMatchObject({
      totalPlayCount: 1,
      totalListenedMs: 1000,
      weekFavoriteAdds: 1,
    });
  });

  it("迁移旧记录并在恢复和追加时限制记录数量", async () => {
    const events = Array.from({ length: 5001 }, () => ({
      track,
      startedAt: Date.now(),
      listenedMs: 1000,
    }));
    localStorage.setItem("splayer.mobile.stats.plays", JSON.stringify(events));
    const { mobileStats } = await import("./stats");
    expect(await mobileStats.getStatsSummary()).toMatchObject({ totalPlayCount: 5000 });
    mobileStats.recordPlay({ track, startedAt: Date.now(), listenedMs: 2000 });
    expect(await mobileStats.getStatsSummary()).toMatchObject({
      totalPlayCount: 5000,
      totalListenedMs: 5001000,
    });
    await vi.waitFor(() => expect(indexedStorage.values.get("plays")).toHaveLength(5000));
    expect(localStorage.getItem("splayer.mobile.stats.plays")).toBeNull();
  });
});
