import { clearLyricStorage } from "./shims/lyricStorage";
import localforage from "localforage";
import type { TrackSource } from "@shared/types/player";
import { isTauri } from "@tauri-apps/api/core";
import { appCacheDir, join } from "@tauri-apps/api/path";
import { exists, mkdir, remove, writeFile } from "@tauri-apps/plugin-fs";
import { fetchWithProxy } from "./shims/proxy";
import { store } from "./shims/store";

const categories = [
  { id: "lyric", prefix: "splayer.mobile.lyric." },
  { id: "lyricTTML", prefix: "splayer.mobile.ttml." },
  { id: "lyricMatch", prefix: "splayer.mobile.lyric-match." },
];
const SONG_CACHE_NAME = "splayer-mobile-songs-v1";
const NATIVE_SONG_CACHE_DIR = "splayer-song-cache";
const songMeta = localforage.createInstance({ name: "splayer", storeName: "song-cache" });
interface SongMeta {
  key: string;
  source: TrackSource;
  size: number;
  lastUsedAt: number;
  filePath?: string;
}

const cacheRequest = (key: string): Request =>
  new Request(`https://splayer.invalid/mobile-cache/${encodeURIComponent(key)}`);
const cacheStorage = (): CacheStorage | null =>
  typeof globalThis.caches === "undefined" ? null : globalThis.caches;

const keyFingerprint = (value: string): string => {
  let first = 2166136261;
  let second = 2246822519;
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    first = Math.imul(first ^ code, 16777619);
    second = Math.imul(second ^ code, 3267000013);
  }
  return `${(first >>> 0).toString(16).padStart(8, "0")}-${(second >>> 0).toString(16).padStart(8, "0")}`;
};

const nativeAudioExtension = (url: string, mimeType: string | null, data?: Uint8Array): string => {
  const mime = mimeType?.split(";", 1)[0].toLowerCase();
  const byMime: Record<string, string> = {
    "audio/aac": "aac",
    "audio/flac": "flac",
    "audio/mp4": "m4a",
    "audio/mpeg": "mp3",
    "audio/ogg": "ogg",
    "audio/opus": "opus",
    "audio/wav": "wav",
    "audio/x-m4a": "m4a",
    "audio/x-wav": "wav",
  };
  if (mime && byMime[mime]) return byMime[mime];
  try {
    const extension = new URL(url).pathname.split(".").pop()?.toLowerCase();
    if (extension && /^(aac|ape|flac|m4a|mp3|ogg|opus|wav)$/.test(extension)) return extension;
  } catch {}
  if (data) {
    const text = (offset: number, length: number): string =>
      String.fromCharCode(...data.slice(offset, offset + length));
    if (text(0, 4) === "fLaC") return "flac";
    if (text(0, 4) === "OggS") return "ogg";
    if (text(0, 4) === "RIFF" && text(8, 4) === "WAVE") return "wav";
    if (text(4, 4) === "ftyp") return "m4a";
    if (text(0, 3) === "ID3" || (data[0] === 0xff && (data[1] & 0xe0) === 0xe0)) return "mp3";
  }
  return "mp3";
};

const nativeSongDirectory = async (): Promise<string> => {
  const directory = await join(await appCacheDir(), NATIVE_SONG_CACHE_DIR);
  await mkdir(directory, { recursive: true });
  return directory;
};

const fileUrl = (path: string): string =>
  `file://${path
    .split("/")
    .map((part) => encodeURIComponent(part))
    .join("/")}`;

const removeNativeSong = async (value: SongMeta | null | undefined): Promise<void> => {
  if (value?.filePath) await remove(value.filePath).catch(() => undefined);
};

const writeNativeSong = async (
  key: string,
  url: string,
  response: Response,
  value: SongMeta | null,
): Promise<{ path: string; size: number }> => {
  const data = new Uint8Array(await response.arrayBuffer());
  const directory = await nativeSongDirectory();
  const extension = nativeAudioExtension(url, response.headers.get("content-type"), data);
  const path = await join(directory, `${keyFingerprint(key)}.${extension}`);
  if (value?.filePath && value.filePath !== path) await removeNativeSong(value);
  await writeFile(path, data);
  return { path, size: data.byteLength };
};

const songLimit = (): number => {
  const gb = Number(store.get("cache.songCache.sizeLimitGb"));
  return Number.isFinite(gb) && gb > 0 ? gb * 1024 ** 3 : Infinity;
};

const evictSongs = async (): Promise<void> => {
  const storage = cacheStorage();
  const cache = storage ? await storage.open(SONG_CACHE_NAME) : null;
  const keys = await songMeta.keys();
  const entries = (
    await Promise.all(
      keys.map(async (key) => ({ key, value: await songMeta.getItem<SongMeta>(key) })),
    )
  ).filter((item): item is { key: string; value: SongMeta } => Boolean(item.value));
  let total = entries.reduce((sum, item) => sum + item.value.size, 0);
  for (const item of entries.sort((a, b) => a.value.lastUsedAt - b.value.lastUsedAt)) {
    if (total <= songLimit()) break;
    await cache?.delete(cacheRequest(item.value.key));
    await removeNativeSong(item.value);
    await songMeta.removeItem(item.key);
    total -= item.value.size;
  }
};

/** 统计可重新获取的歌词与歌曲缓存，不包含账号、歌单与下载文件。 */
export const mobileCache = {
  getStats: async () => {
    const stats = await Promise.all(
      categories.map(async ({ id, prefix }) => {
        let size = 0;
        for (let index = 0; index < localStorage.length; index++) {
          const key = localStorage.key(index);
          if (key?.startsWith(prefix))
            size += (key.length + (localStorage.getItem(key)?.length ?? 0)) * 2;
        }
        return { id, kind: "db" as const, path: "localStorage", size };
      }),
    );
    const keys = await songMeta.keys();
    const values = await Promise.all(keys.map((key) => songMeta.getItem<SongMeta>(key)));
    const songSize = values.reduce((sum, value) => sum + (value?.size ?? 0), 0);
    return songSize > 0
      ? [
          ...stats,
          {
            id: "songs",
            kind: "db" as const,
            path: isTauri() ? "App Cache" : "Cache Storage",
            size: songSize,
          },
        ]
      : stats;
  },
  clear: async (id: string) => {
    if (id === "songs") {
      const storage = cacheStorage();
      if (storage) {
        const cache = await storage.open(SONG_CACHE_NAME);
        await Promise.all((await cache.keys()).map((request) => cache.delete(request)));
      }
      const keys = await songMeta.keys();
      await Promise.all(
        keys.map(async (key) => removeNativeSong(await songMeta.getItem<SongMeta>(key))),
      );
      await songMeta.clear();
      return;
    }
    const category = categories.find((item) => item.id === id);
    if (!category) throw new Error("未知的缓存分类");
    clearLyricStorage(category.prefix);
  },
  clearAllByKind: async (kind: "file" | "db") => {
    if (kind === "db") {
      categories.forEach(({ prefix }) => clearLyricStorage(prefix));
      await mobileCache.clear("songs");
    }
  },
  getDir: async () => "",
  pickDir: async () => ({ ok: false as const, reason: "canceled" as const }),
  resetDir: async () => "",
  song: {
    lookup: async (key: string) => {
      if (!store.get("cache.songCache.enabled")) return null;
      const storage = cacheStorage();
      const value = await songMeta.getItem<SongMeta>(key);
      if (isTauri() && value?.filePath && (await exists(value.filePath))) {
        await songMeta.setItem(key, { ...value, lastUsedAt: Date.now() });
        return fileUrl(value.filePath);
      }
      if (!storage) return null;
      const response = await (await storage.open(SONG_CACHE_NAME)).match(cacheRequest(key));
      if (!response) return null;
      if (isTauri()) {
        try {
          const native = await writeNativeSong(key, key, response, value);
          const next = value
            ? {
                ...value,
                filePath: native.path,
                size: value.size || native.size,
                lastUsedAt: Date.now(),
              }
            : {
                key,
                source: "netease" as TrackSource,
                size: native.size,
                filePath: native.path,
                lastUsedAt: Date.now(),
              };
          await songMeta.setItem(key, next);
          return fileUrl(native.path);
        } catch {
          return null;
        }
      }
      if (value) await songMeta.setItem(key, { ...value, lastUsedAt: Date.now() });
      return URL.createObjectURL(await response.blob());
    },
    fetch: async (key: string, source: TrackSource, streamUrl: string) => {
      if (!store.get("cache.songCache.enabled")) return null;
      const response = await fetchWithProxy(streamUrl);
      if (!response.ok || !response.body) return null;
      const storage = cacheStorage();
      if (!storage && !isTauri()) return null;
      const cache = storage && !isTauri() ? await storage.open(SONG_CACHE_NAME) : null;
      const value = await songMeta.getItem<SongMeta>(key);
      const nativeResponse = isTauri() ? response : null;
      const size = Number(response.headers.get("content-length")) || 0;
      let filePath = value?.filePath;
      let nativeSize = 0;
      if (cache) await cache.put(cacheRequest(key), response.clone());
      if (nativeResponse) {
        const native = await writeNativeSong(key, streamUrl, nativeResponse, value);
        filePath = native.path;
        nativeSize = native.size;
      }
      await songMeta.setItem(key, {
        key,
        source,
        size: size || nativeSize,
        lastUsedAt: Date.now(),
        ...(filePath ? { filePath } : {}),
      });
      await evictSongs();
      return mobileCache.song.lookup(key);
    },
    cancel: async () => undefined,
  },
};
