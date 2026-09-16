import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";

vi.mock("./library", () => ({ mobileLibrary: {} }));
const track: Track = { id: "1", source: "netease", title: "红豆", artists: [], duration: 240000 };

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
  vi.resetModules();
});

afterEach(() => vi.unstubAllGlobals());

describe("移动端统计存储", () => {
  it("配额耗尽不打断播放和收藏且会话统计仍可读取", async () => {
    const { mobileStats } = await import("./stats");
    const write = vi.spyOn(localStorage, "setItem").mockImplementation(() => {
      throw new DOMException("full", "QuotaExceededError");
    });
    expect(() =>
      mobileStats.recordPlay({ track, startedAt: Date.now(), listenedMs: 1000 }),
    ).not.toThrow();
    expect(() => mobileStats.recordFavorite({ track, action: "add" })).not.toThrow();
    expect(write).toHaveBeenCalled();
    expect(await mobileStats.getStatsSummary()).toMatchObject({
      totalPlayCount: 1,
      totalListenedMs: 1000,
      weekFavoriteAdds: 1,
    });
  });

  it("恢复和追加时都限制内存记录数量", async () => {
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
    expect(JSON.parse(localStorage.getItem("splayer.mobile.stats.plays")!)).toHaveLength(5000);
  });
});
