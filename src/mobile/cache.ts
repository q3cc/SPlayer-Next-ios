import { clearLyricStorage } from "./shims/lyricStorage";
import localforage from "localforage";
import type { TrackSource } from "@shared/types/player";
import { fetchWithProxy } from "./shims/proxy";
import { store } from "./shims/store";

const categories = [
  { id: "lyric", prefix: "splayer.mobile.lyric." },
  { id: "lyricTTML", prefix: "splayer.mobile.ttml." },
  { id: "lyricMatch", prefix: "splayer.mobile.lyric-match." },
];
const SONG_CACHE_NAME = "splayer-mobile-songs-v1";
const songMeta = localforage.createInstance({ name: "splayer", storeName: "song-cache" });
interface SongMeta {
  key: string;
  source: TrackSource;
  size: number;
  lastUsedAt: number;
}

const cacheRequest = (key: string): Request =>
  new Request(`https://splayer.invalid/mobile-cache/${encodeURIComponent(key)}`);
const cacheStorage = (): CacheStorage | null =>
  typeof globalThis.caches === "undefined" ? null : globalThis.caches;

const songLimit = (): number => {
  const gb = Number(store.get("cache.songCache.sizeLimitGb"));
  return Number.isFinite(gb) && gb > 0 ? gb * 1024 ** 3 : Infinity;
};

const evictSongs = async (): Promise<void> => {
  const storage = cacheStorage();
  if (!storage) return;
  const cache = await storage.open(SONG_CACHE_NAME);
  const keys = await songMeta.keys();
  const entries = (
    await Promise.all(
      keys.map(async (key) => ({ key, value: await songMeta.getItem<SongMeta>(key) })),
    )
  ).filter((item): item is { key: string; value: SongMeta } => Boolean(item.value));
  let total = entries.reduce((sum, item) => sum + item.value.size, 0);
  for (const item of entries.sort((a, b) => a.value.lastUsedAt - b.value.lastUsedAt)) {
    if (total <= songLimit()) break;
    await cache.delete(cacheRequest(item.value.key));
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
      ? [...stats, { id: "songs", kind: "db" as const, path: "Cache Storage", size: songSize }]
      : stats;
  },
  clear: async (id: string) => {
    if (id === "songs") {
      const storage = cacheStorage();
      if (storage) {
        const cache = await storage.open(SONG_CACHE_NAME);
        await Promise.all((await cache.keys()).map((request) => cache.delete(request)));
      }
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
      if (!storage) return null;
      const response = await (await storage.open(SONG_CACHE_NAME)).match(cacheRequest(key));
      if (!response) return null;
      const value = await songMeta.getItem<SongMeta>(key);
      if (value) await songMeta.setItem(key, { ...value, lastUsedAt: Date.now() });
      return URL.createObjectURL(await response.blob());
    },
    fetch: async (key: string, source: TrackSource, streamUrl: string) => {
      if (!store.get("cache.songCache.enabled")) return null;
      const response = await fetchWithProxy(streamUrl);
      if (!response.ok || !response.body) return null;
      const storage = cacheStorage();
      if (!storage) return null;
      const size = Number(response.headers.get("content-length")) || 0;
      const cache = await storage.open(SONG_CACHE_NAME);
      await cache.put(cacheRequest(key), response.clone());
      await songMeta.setItem(key, { key, source, size, lastUsedAt: Date.now() });
      await evictSongs();
      return mobileCache.song.lookup(key);
    },
    cancel: async () => undefined,
  },
};
