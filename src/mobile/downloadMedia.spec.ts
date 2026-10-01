import { beforeEach, expect, it, vi } from "vitest";
import type { DownloadRequest } from "@shared/types/download";

const mocks = vi.hoisted(() => ({
  files: new Map<string, string | Uint8Array>(),
  index: new Map<string, string[]>(),
  fetch: vi.fn(),
}));

vi.mock("localforage", () => ({
  default: {
    createInstance: () => ({
      getItem: async (key: string) => mocks.index.get(key) ?? null,
      setItem: async (key: string, value: string[]) => mocks.index.set(key, value),
      removeItem: async (key: string) => mocks.index.delete(key),
    }),
  },
}));
vi.mock("@tauri-apps/api/path", () => ({
  documentDir: async () => "/Documents",
  join: async (...parts: string[]) => parts.join("/"),
}));
vi.mock("@tauri-apps/plugin-fs", () => ({
  exists: async (path: string) => mocks.files.has(path),
  readTextFile: async (path: string) => {
    if (!mocks.files.has(path)) throw new Error("missing");
    return String(mocks.files.get(path));
  },
  writeTextFile: async (path: string, value: string) => mocks.files.set(path, value),
  rename: async (source: string, target: string) => {
    mocks.files.set(target, mocks.files.get(source)!);
    mocks.files.delete(source);
  },
  remove: async (path: string) => mocks.files.delete(path),
  open: async (path: string) => {
    mocks.files.set(path, new Uint8Array());
    return {
      write: async (bytes: Uint8Array) => {
        const existing = mocks.files.get(path) as Uint8Array;
        mocks.files.set(path, Uint8Array.from([...existing, ...bytes]));
        return bytes.length;
      },
      close: async () => undefined,
    };
  },
}));
vi.mock("./shims/proxy", () => ({ fetchWithProxy: mocks.fetch }));

const track = {
  id: "1",
  source: "netease" as const,
  title: "离线歌曲",
  artists: [{ name: "歌手" }],
  duration: 200000,
  cover: "https://example.com/cover.jpg?secret=abc",
};
const request: DownloadRequest = {
  taskId: "one",
  track,
  qualityLevel: "hq",
  lyricText: "[00:01.00]离线歌词",
  ttmlText: "<tt>逐字歌词</tt>",
  tagOptions: {
    embedCover: false,
    embedMeta: false,
    embedLyric: false,
    writeLrc: false,
    saveTtml: false,
  },
  usePlaybackForDownload: false,
  lyricFileFormat: "lrc",
};

beforeEach(() => {
  mocks.files.clear();
  mocks.index.clear();
  mocks.fetch.mockReset().mockResolvedValue(
    new Response(new Uint8Array([1, 2, 3]), {
      headers: { "content-type": "image/jpeg" },
    }),
  );
});

it("下载后离线查找本地音频、封面和双格式歌词，重启后路径仍可恢复", async () => {
  const path = "/Documents/Downloads/Artist - Song.flac";
  mocks.files.set(path, new Uint8Array([9]));
  const { saveDownloadMedia, findDownloadMedia, readDownloadMedia } =
    await import("./downloadMedia");
  expect(await saveDownloadMedia(request, path)).toBe(false);
  expect(mocks.files.get(path + ".cover.jpg")).toEqual(new Uint8Array([1, 2, 3]));
  expect(mocks.files.get(path + ".lrc")).toBe(request.lyricText);
  expect(mocks.files.get(path + ".ttml")).toBe(request.ttmlText);
  expect(String(mocks.files.get(path + ".splayer.json"))).not.toContain("secret=abc");
  vi.resetModules();
  expect(await (await import("./downloadMedia")).findDownloadMedia(track)).toMatchObject({
    audioPath: path,
    coverPath: path + ".cover.jpg",
    externalLyrics: [
      { format: "lrc", path: path + ".lrc" },
      { format: "ttml", path: path + ".ttml" },
    ],
  });
  expect(await findDownloadMedia(track)).toEqual(await readDownloadMedia(path));
});

it("删除只清理目标音频及附属资源，不误删另一份同曲下载", async () => {
  const { saveDownloadMedia, findDownloadMedia, removeDownloadMedia } =
    await import("./downloadMedia");
  const first = "/Documents/Downloads/song.mp3";
  const second = "/Documents/Downloads/song.flac";
  mocks.files.set(first, new Uint8Array([1]));
  mocks.files.set(second, new Uint8Array([2]));
  await saveDownloadMedia(request, first);
  await saveDownloadMedia(request, second);
  await removeDownloadMedia(second);
  expect(mocks.files.has(second)).toBe(false);
  expect(mocks.files.has(second + ".cover.jpg")).toBe(false);
  expect((await findDownloadMedia(track))?.audioPath).toBe(first);
});

it("封面失败仍保存音频和歌词并标记警告", async () => {
  const { saveDownloadMedia, findDownloadMedia } = await import("./downloadMedia");
  const path = "/Documents/Downloads/song.mp3";
  mocks.files.set(path, new Uint8Array([1]));
  mocks.fetch.mockRejectedValue(new Error("offline"));
  expect(await saveDownloadMedia(request, path)).toBe(true);
  expect(await findDownloadMedia(track)).toMatchObject({
    audioPath: path,
    externalLyrics: expect.arrayContaining([{ format: "lrc", path: path + ".lrc" }]),
  });
});

it("重新下载附属资源失败时保留同一首歌已有的本地封面", async () => {
  const { saveDownloadMedia, findDownloadMedia } = await import("./downloadMedia");
  const path = "/Documents/Downloads/song.mp3";
  mocks.files.set(path, new Uint8Array([1]));
  await saveDownloadMedia(request, path);
  mocks.fetch.mockRejectedValue(new Error("offline"));
  await saveDownloadMedia(request, path);
  expect((await findDownloadMedia(track))?.coverPath).toBe(path + ".cover.jpg");
});
