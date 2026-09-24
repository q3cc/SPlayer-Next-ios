import { beforeEach, expect, it, vi } from "vitest";

const { files, meta, fetchWithProxy, writeFile, remove } = vi.hoisted(() => {
  const files = new Map<string, Uint8Array>();
  const values = new Map<string, unknown>();
  return {
    files,
    meta: {
      keys: vi.fn(async () => [...values.keys()]),
      getItem: vi.fn(async (key: string) => values.get(key) ?? null),
      setItem: vi.fn(async (key: string, value: unknown) => {
        values.set(key, value);
        return value;
      }),
      removeItem: vi.fn(async (key: string) => values.delete(key)),
      clear: vi.fn(async () => values.clear()),
    },
    fetchWithProxy: vi.fn(),
    writeFile: vi.fn(async (path: string, data: Uint8Array) => files.set(path, data)),
    remove: vi.fn(async (path: string) => files.delete(path)),
  };
});

vi.mock("localforage", () => ({ default: { createInstance: () => meta } }));
vi.mock("@tauri-apps/api/core", () => ({ isTauri: () => true }));
vi.mock("@tauri-apps/api/path", () => ({
  appCacheDir: async () => "/app/cache",
  join: async (...parts: string[]) => parts.join("/"),
}));
vi.mock("@tauri-apps/plugin-fs", () => ({
  exists: async (path: string) => files.has(path),
  mkdir: vi.fn(),
  remove,
  writeFile,
}));
vi.mock("./shims/proxy", () => ({ fetchWithProxy }));
vi.mock("./shims/store", () => ({
  store: { get: (key: string) => (key === "cache.songCache.enabled" ? true : 10) },
}));

beforeEach(() => {
  files.clear();
  meta.keys.mockClear();
  meta.getItem.mockClear();
  meta.setItem.mockClear();
  meta.removeItem.mockClear();
  meta.clear.mockClear();
  fetchWithProxy.mockReset();
  writeFile.mockClear();
  remove.mockClear();
  localStorage.clear();
});

it("iOS 歌曲缓存写入 AppCache 并返回原生播放器可读取的文件 URL", async () => {
  fetchWithProxy.mockResolvedValue(
    new Response(new Uint8Array([1, 2, 3]), {
      headers: { "content-type": "audio/mp4", "content-length": "3" },
    }),
  );
  const { mobileCache } = await import("./cache");

  const source = await mobileCache.song.fetch(
    "o:netease:42:hq",
    "netease",
    "https://music.example/song.m4a",
  );

  expect(source).toMatch(/^file:\/\/\/app\/cache\/splayer-song-cache\/[\da-f-]+\.m4a$/);
  expect(writeFile).toHaveBeenCalledOnce();
  expect(await mobileCache.getStats()).toContainEqual(
    expect.objectContaining({ id: "songs", path: "App Cache", size: 3 }),
  );

  await mobileCache.clear("songs");
  expect(remove).toHaveBeenCalledOnce();
  expect(files.size).toBe(0);
});
