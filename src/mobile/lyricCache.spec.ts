import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clearLyricCache, getCachedLyric, setCachedLyric } from "./shims/lyricCache";
import { clearLyricMatchCache, getMatchedId, setMatchedId } from "./shims/lyricMatchCache";
import { clearLyricTtmlCache, getCachedTTML, setCachedTTML } from "./shims/lyricTtmlCache";
import { getByPlatformId, getByQuery } from "@main/apis/common/lyric/netease";

vi.mock("@main/database/lyricCache", () => import("./shims/lyricCache"));
vi.mock("@main/database/lyricMatchCache", () => import("./shims/lyricMatchCache"));
vi.mock("@main/apis/common/lyric/ttml", () => ({ prefetchTTML: vi.fn() }));
vi.mock("@main/utils/logger", () => ({ coreLog: { info: vi.fn(), warn: vi.fn() } }));
const { callNetease } = vi.hoisted(() => ({ callNetease: vi.fn() }));
vi.mock("@main/apis/netease", () => ({ callNetease }));

const lyric = { platform: "netease", format: "lrc", content: "[00:01.00]红豆" } as const;

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
});

afterEach(() => vi.unstubAllGlobals());

describe("移动端歌词缓存", () => {
  it("保留歌词、匹配映射及 TTML 的缓存语义", () => {
    expect(getCachedLyric("netease", "1")).toBeNull();
    expect(getMatchedId("song", "netease")).toBeNull();
    expect(getCachedTTML("netease", "1")).toBe("miss");
    setCachedLyric("netease", "1", lyric);
    setMatchedId("song", "netease", "1");
    setCachedTTML("netease", "1", "<tt>歌词</tt>");
    setCachedTTML("netease", "2", null);
    expect(getCachedLyric("netease", "1")).toEqual(lyric);
    expect(getMatchedId("song", "netease")).toEqual({ platformId: "1" });
    expect(getCachedTTML("netease", "1")).toBe("<tt>歌词</tt>");
    expect(getCachedTTML("netease", "2")).toBeNull();
    clearLyricCache();
    expect(getMatchedId("song", "netease")).not.toBeNull();
    clearLyricMatchCache();
    clearLyricTtmlCache();
    expect(localStorage.length).toBe(0);
  });

  it("配额耗尽时在线歌词依然成功返回，模糊匹配也不中断", async () => {
    vi.spyOn(localStorage, "setItem").mockImplementation(() => {
      throw new DOMException("The quota has been exceeded.", "QuotaExceededError");
    });
    callNetease.mockImplementation(async (name: string) => ({
      status: 200,
      body:
        name === "search"
          ? {
              result: {
                songs: [
                  { id: 28029104, name: "红豆", artists: [{ name: "方大同" }], duration: 240000 },
                ],
              },
            }
          : { code: 200, lrc: { lyric: lyric.content } },
    }));
    expect(await getByPlatformId("28029104")).toMatchObject(lyric);
    expect(
      await getByQuery({
        id: "local",
        source: "local",
        title: "红豆",
        artists: [{ name: "方大同" }],
        duration: 240000,
      }),
    ).toMatchObject(lyric);
    expect(() => setCachedTTML("netease", "1", "<tt />")).not.toThrow();
  });

  it("配额不足时只释放歌词缓存并重试", () => {
    localStorage.setItem("user.settings", "keep");
    setCachedTTML("netease", "old", "<tt />");
    const setItem = vi.spyOn(localStorage, "setItem");
    setItem.mockImplementationOnce(() => {
      throw new DOMException("full", "QuotaExceededError");
    });
    setCachedLyric("netease", "new", lyric);
    expect(getCachedLyric("netease", "new")).toEqual(lyric);
    expect(getCachedTTML("netease", "old")).toBe("miss");
    expect(localStorage.getItem("user.settings")).toBe("keep");
  });

  it("存储被禁用时按未命中处理且写入和清理不抛错", () => {
    vi.spyOn(localStorage, "getItem").mockImplementation(() => {
      throw new DOMException("denied", "SecurityError");
    });
    vi.spyOn(localStorage, "setItem").mockImplementation(() => {
      throw new DOMException("denied", "SecurityError");
    });
    expect(getCachedTTML("netease", "1")).toBe("miss");
    expect(getCachedLyric("netease", "1")).toBeNull();
    expect(getMatchedId("song", "netease")).toBeNull();
    expect(() => setMatchedId("song", "netease", "1")).not.toThrow();
    expect(() => clearLyricCache()).not.toThrow();
  });

  it("限制缓存数量并在旧缓存已超限时收敛", () => {
    for (let index = 0; index < 300; index++) {
      localStorage.setItem("splayer.mobile.lyric-match.netease." + index, '{"platformId":"1"}');
    }
    setCachedLyric("netease", "new", lyric);
    expect(localStorage.length).toBeLessThanOrEqual(256);
    expect(getCachedLyric("netease", "new")).toEqual(lyric);
  });

  it("限制缓存总大小，超大歌词跳过缓存而不保留内存副本", () => {
    const content = "词".repeat(200000);
    for (let index = 0; index < 4; index++) setCachedTTML("netease", String(index), content);
    expect(localStorage.length).toBe(2);
    setCachedTTML("netease", "huge", "词".repeat(512 * 1024));
    expect(getCachedTTML("netease", "huge")).toBe("miss");
  });
});
