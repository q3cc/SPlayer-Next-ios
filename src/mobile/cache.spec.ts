import { beforeEach, describe, expect, it, vi } from "vitest";
import { webcrypto } from "node:crypto";
const mocks = vi.hoisted(() => ({
  files: new Map<string, Uint8Array>(),
  saved: undefined as unknown,
  fetch: vi.fn(),
  enabled: true,
  streaming: false,
  gb: 10,
}));
vi.mock("@tauri-apps/api/path", () => ({
  appCacheDir: async () => "/cache",
  join: async (...parts: string[]) => parts.join("/"),
}));
vi.mock("./shims/proxy", () => ({ fetchWithProxy: mocks.fetch }));
vi.mock("./shims/store", () => ({
  store: {
    get: (key: string) =>
      key.endsWith("enabled")
        ? mocks.enabled
        : key.endsWith("cacheStreaming")
          ? mocks.streaming
          : mocks.gb,
  },
}));
vi.mock("localforage", () => ({
  default: {
    createInstance: () => ({
      getItem: async () => structuredClone(mocks.saved),
      setItem: async (_key: string, value: unknown) => {
        mocks.saved = structuredClone(value);
      },
    }),
  },
}));
vi.mock("@tauri-apps/plugin-fs", () => ({
  mkdir: async () => undefined,
  exists: async (path: string) => mocks.files.has(path),
  stat: async (path: string) => ({ size: mocks.files.get(path)!.length }),
  readDir: async () =>
    Array.from(mocks.files.keys(), (path) => ({
      name: path.split("/").pop(),
      isFile: true,
      isSymlink: false,
    })),
  remove: async (path: string) => {
    mocks.files.delete(path);
  },
  rename: async (from: string, to: string) => {
    mocks.files.set(to, mocks.files.get(from)!);
    mocks.files.delete(from);
  },
  open: async (path: string) => {
    mocks.files.set(path, new Uint8Array());
    return {
      close: async () => undefined,
      write: async (data: Uint8Array) => {
        const old = mocks.files.get(path)!;
        // 模拟短写，验证每个分块都被完整写入。
        const length = Math.min(2, data.length);
        const next = new Uint8Array(old.length + length);
        next.set(old);
        next.set(data.subarray(0, length), old.length);
        mocks.files.set(path, next);
        return length;
      },
    };
  },
}));
const response = (size = 4, expected = size) =>
  new Response(new Uint8Array(size).fill(7), {
    headers: { "content-type": "audio/flac", "content-length": String(expected) },
  });
beforeEach(() => {
  vi.resetModules();
  vi.stubGlobal("crypto", webcrypto);
  mocks.files.clear();
  mocks.saved = undefined;
  mocks.enabled = true;
  mocks.streaming = false;
  mocks.gb = 10;
  mocks.fetch.mockReset().mockImplementation(async () => response());
  localStorage.clear();
});
describe("iOS 缓存与离线播放", () => {
  it("流式短写完成后才能离线命中，不保存授权链接", async () => {
    const { mobileCache } = await import("./cache");
    const path = await mobileCache.song.fetch(
      "o:netease:1:hq",
      "netease",
      "https://music.test/a?token=secret",
    );
    expect(path).toMatch(/^\/cache\/offline-songs\/[a-f0-9]{64}\.flac$/);
    expect(mocks.files.get(path!)).toEqual(new Uint8Array(4).fill(7));
    mocks.fetch.mockRejectedValue(new Error("offline"));
    expect(await mobileCache.song.lookup("o:netease:1:hq")).toBe(path);
    expect(await mobileCache.song.lookup("o:netease:1:lossless")).toBeNull();
    expect(JSON.stringify(mocks.saved)).not.toContain("secret");
    expect(mocks.fetch).toHaveBeenCalledTimes(1);
  });
  it("重启后恢复相对文件名，系统清理后返回未命中", async () => {
    let api = (await import("./cache")).mobileCache;
    const path = await api.song.fetch("song", "netease", "https://music.test/a.flac");
    vi.resetModules();
    api = (await import("./cache")).mobileCache;
    expect(await api.song.lookup("song")).toBe(path);
    mocks.files.delete(path!);
    expect(await api.song.lookup("song")).toBeNull();
  });
  it.each(["truncated", "empty", "html", "partial"])("拒绝不完整或非音频响应：%s", async (kind) => {
    mocks.fetch.mockResolvedValue(
      kind === "truncated"
        ? response(4, 5)
        : kind === "empty"
          ? response(0)
          : kind === "partial"
            ? new Response("audio", { status: 206 })
            : new Response("login", { headers: { "content-type": "text/html" } }),
    );
    const api = (await import("./cache")).mobileCache;
    expect(await api.song.fetch("a", "netease", "https://music.test/a")).toBeNull();
    expect(await api.song.lookup("a")).toBeNull();
    expect(mocks.files.size).toBe(0);
  });
  it("遵守开关且不缓存本地音频，流媒体需单独开启", async () => {
    const api = (await import("./cache")).mobileCache;
    mocks.enabled = false;
    await api.song.fetch("a", "netease", "https://music.test/a");
    mocks.enabled = true;
    await api.song.fetch("b", "local", "https://music.test/b");
    await api.song.fetch("c", "streaming", "https://music.test/c");
    expect(mocks.fetch).not.toHaveBeenCalled();
    mocks.streaming = true;
    expect(await api.song.fetch("c", "streaming", "https://music.test/c")).not.toBeNull();
  });
  it("相同任务复用，快速切歌不积累待下载链接", async () => {
    const api = (await import("./cache")).mobileCache;
    const first = api.song.fetch("a", "netease", "https://music.test/a");
    expect(api.song.fetch("a", "netease", "https://music.test/a")).toBe(first);
    expect(await api.song.fetch("b", "netease", "https://music.test/b")).toBeNull();
    await first;
    expect(mocks.fetch).toHaveBeenCalledTimes(1);
  });
  it("按空间上限淘汰旧缓存并保护最近播放的文件", async () => {
    const api = (await import("./cache")).mobileCache;
    mocks.gb = 8 / 1024 ** 3;
    await api.song.fetch("a", "netease", "https://music.test/a");
    await api.song.fetch("b", "netease", "https://music.test/b");
    await api.song.lookup("a");
    await api.song.lookup("not-cached");
    await api.song.fetch("c", "netease", "https://music.test/c");
    expect(await api.song.lookup("a")).not.toBeNull();
    expect(await api.song.lookup("b")).toBeNull();
    expect(await api.song.lookup("c")).not.toBeNull();
    expect((await api.getStats())[0].size).toBe(8);
  });
  it("未知长度超限也中止写入并清理临时文件", async () => {
    const api = (await import("./cache")).mobileCache;
    mocks.gb = 3 / 1024 ** 3;
    mocks.fetch.mockResolvedValue(new Response(new Uint8Array(4)));
    expect(await api.song.fetch("a", "netease", "https://music.test/a")).toBeNull();
    expect(mocks.files.size).toBe(0);
  });
  it("清理会等待活动下载取消，不会留下完成后的缓存", async () => {
    const api = (await import("./cache")).mobileCache;
    mocks.fetch.mockImplementation(
      (_url: unknown, options: RequestInit) =>
        new Promise((_resolve, reject) => {
          options.signal!.addEventListener("abort", () => reject(new Error("aborted")), {
            once: true,
          });
        }),
    );
    const task = api.song.fetch("a", "netease", "https://music.test/a");
    await vi.waitFor(() => expect(mocks.fetch).toHaveBeenCalledTimes(1));
    await api.clear("songs");
    expect(await task).toBeNull();
    expect(mocks.files.size).toBe(0);
  });
  it("歌词统计和清理仅触碰对应缓存，不清除账号与下载记录", async () => {
    const api = (await import("./cache")).mobileCache;
    localStorage.setItem("splayer.mobile.lyric.a", "lyric");
    localStorage.setItem("splayer.mobile.ttml.b", "ttml");
    localStorage.setItem("account", "keep");
    expect((await api.getStats()).find((item) => item.id === "lyric")!.size).toBeGreaterThan(0);
    await api.clearAllByKind("db");
    expect(localStorage.getItem("account")).toBe("keep");
    expect(localStorage.getItem("splayer.mobile.ttml.b")).toBeNull();
    await expect(api.clear("account")).rejects.toThrow();
    expect(await api.pickDir()).toMatchObject({ ok: false });
  });
  it("统计会排除系统已回收的文件", async () => {
    const api = (await import("./cache")).mobileCache;
    const path = await api.song.fetch("a", "netease", "https://music.test/a");
    mocks.files.delete(path!);
    expect((await api.getStats())[0].size).toBe(0);
  });
  it("取消指定歌曲后可以重新缓存", async () => {
    const api = (await import("./cache")).mobileCache;
    const first = api.song.fetch("a", "netease", "https://music.test/a");
    await api.song.cancel("a");
    expect(await first).toBeNull();
    expect(await api.song.fetch("a", "netease", "https://music.test/a")).not.toBeNull();
  });
  it("初始化清理中断的临时文件和无索引音频", async () => {
    mocks.files.set("/cache/offline-songs/stale.part", new Uint8Array(4));
    mocks.files.set("/cache/offline-songs/orphan.mp3", new Uint8Array(4));
    const api = (await import("./cache")).mobileCache;
    await api.getStats();
    expect(mocks.files.size).toBe(0);
  });
});
