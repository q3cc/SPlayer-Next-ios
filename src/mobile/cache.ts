import { appCacheDir, join } from "@tauri-apps/api/path";
import { exists, mkdir, open, readDir, remove, rename, stat } from "@tauri-apps/plugin-fs";
import localforage from "localforage";
import { fetchWithProxy } from "./shims/proxy";
import { store } from "./shims/store";
import { clearLyricStorage } from "./shims/lyricStorage";

type CacheApi = Window["api"]["cache"];
interface Entry {
  name: string;
  size: number;
  used: number;
}
const MAX_ENTRIES = 2048;
const storage = localforage.createInstance({ name: "splayer", storeName: "song-cache" });
const prefixes: Record<string, string> = {
  lyric: "splayer.mobile.lyric.",
  lyricTTML: "splayer.mobile.ttml.",
  lyricMatch: "splayer.mobile.lyric-match.",
};
let entries: Entry[] = [];
let initialized: Promise<void> | undefined;
let locked = Promise.resolve();
let protectedName: string | undefined;
let clearing = 0;
let active:
  { key: string; controller: AbortController; promise: Promise<string | null> } | undefined;
const getDir = async (): Promise<string> => join(await appCacheDir(), "offline-songs");
const limit = (): number => {
  const gb = store.get("cache.songCache.sizeLimitGb");
  return gb > 0 ? gb * 1024 ** 3 : Infinity;
};

/** 元数据操作串行执行，防止清理与下载完成互相覆盖。 */
const exclusive = <T>(work: () => Promise<T>): Promise<T> => {
  const result = locked.then(work);
  locked = result.then(
    () => undefined,
    () => undefined,
  );
  return result;
};
const save = async (): Promise<void> => {
  await storage.setItem("entries", entries);
};
const initialize = (): Promise<void> => {
  initialized ??= (async () => {
    const root = await getDir();
    await mkdir(root, { recursive: true });
    const saved = await storage.getItem<Entry[]>("entries");
    const names = new Map(
      (Array.isArray(saved) ? saved : [])
        .slice(0, MAX_ENTRIES)
        .filter((entry) => entry && /^[a-f0-9]{64}\.[a-z0-9]+$/.test(entry.name))
        .map((entry) => [entry.name, entry]),
    );
    entries = [];
    for (const file of await readDir(root)) {
      if (!file.isFile || file.isSymlink) continue;
      const path = await join(root, file.name);
      const previous = names.get(file.name);
      if (!previous) {
        await remove(path);
        continue;
      }
      const info = await stat(path);
      if (info.size <= 0 || info.size !== previous.size) {
        await remove(path);
        continue;
      }
      entries.push({ name: file.name, size: info.size, used: Number(previous.used) || 0 });
    }
    await save();
  })().catch((error) => {
    initialized = undefined;
    throw error;
  });
  return initialized;
};
const hashKey = async (key: string): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
};

/** 淘汰最久未播放的缓存；保留最近命中的文件，避免打断正在播放的音频。 */
const trim = async (reserve = 0, incoming = 0): Promise<boolean> => {
  entries.sort((a, b) => a.used - b.used);
  let size = entries.reduce((sum, entry) => sum + entry.size, 0);
  for (const entry of [...entries]) {
    if (size + reserve <= limit() && entries.length + incoming <= MAX_ENTRIES) break;
    if (entry.name === protectedName) continue;
    const path = await join(await getDir(), entry.name);
    if (await exists(path)) await remove(path);
    entries.splice(entries.indexOf(entry), 1);
    size -= entry.size;
  }
  await save();
  return size + reserve <= limit() && entries.length + incoming <= MAX_ENTRIES;
};
const lookup = async (key: string, protect = true): Promise<string | null> => {
  try {
    const hash = await hashKey(key);
    return await exclusive(async () => {
      await initialize();
      const entry = entries.find((item) => item.name.startsWith(hash + "."));
      if (protect && entry) protectedName = entry.name;
      if (!entry) {
        await trim();
        return null;
      }
      const path = await join(await getDir(), entry.name);
      if (!(await exists(path)) || (await stat(path)).size !== entry.size) {
        entries.splice(entries.indexOf(entry), 1);
        if (protect) protectedName = undefined;
        await save();
        return null;
      }
      entry.used = Date.now();
      await trim();
      return path;
    });
  } catch {
    return null;
  }
};

/** 缓存下载只保留一个活动流，不排队持有过期链接，也不把整首音频读进内存。 */
const download = async (
  key: string,
  url: string,
  controller: AbortController,
): Promise<string | null> => {
  let temporary: string | undefined;
  let file: Awaited<ReturnType<typeof open>> | undefined;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const check = (): void => {
    if (controller.signal.aborted || !store.get("cache.songCache.enabled"))
      throw new Error("canceled");
  };
  try {
    const cached = await lookup(key, false);
    if (cached) return cached;
    check();
    const parsed = new URL(url);
    if (!["https:", "http:"].includes(parsed.protocol)) return null;
    const response = await fetchWithProxy(parsed, { signal: controller.signal });
    reader = response.body?.getReader();
    if (response.status !== 200 || !reader) throw new Error("invalid cache response");
    const mime = response.headers.get("content-type")?.split(";")[0] ?? "";
    if (mime.startsWith("text/") || mime.includes("json") || mime.includes("mpegurl"))
      throw new Error("invalid audio response");
    const expected = Number(response.headers.get("content-length")) || 0;
    if (expected > limit()) return null;
    const suffix = parsed.pathname.split(".").pop()?.toLowerCase();
    const extensions = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "alac", "ape"];
    const extension =
      suffix && extensions.includes(suffix)
        ? suffix
        : ((
            {
              "audio/mp4": "m4a",
              "audio/flac": "flac",
              "audio/x-flac": "flac",
              "audio/wav": "wav",
              "audio/ogg": "ogg",
            } as Record<string, string>
          )[mime] ?? "mp3");
    const name = (await hashKey(key)) + "." + extension;
    const root = await getDir();
    temporary = await join(root, name + ".part");
    check();
    file = await open(temporary, { create: true, write: true, truncate: true });
    let size = 0;
    while (true) {
      check();
      const chunk = await reader.read();
      check();
      if (chunk.done) break;
      size += chunk.value.length;
      if (size > limit()) throw new Error("cache size limit");
      let offset = 0;
      while (offset < chunk.value.length) {
        check();
        const written = await file.write(chunk.value.subarray(offset));
        if (written <= 0) throw new Error("cache write failed");
        offset += written;
      }
    }
    if (!size || (expected > 0 && !response.headers.get("content-encoding") && expected !== size))
      throw new Error("incomplete audio response");
    await file.close();
    file = undefined;
    return await exclusive(async () => {
      check();
      if (!(await trim(size, 1))) return null;
      check();
      const path = await join(root, name);
      await rename(temporary!, path);
      temporary = undefined;
      entries.push({ name, size, used: Date.now() });
      await save();
      return path;
    });
  } catch {
    // 缓存失败不影响在线播放，也不把带凭据的链接写入日志。
    return null;
  } finally {
    await reader?.cancel().catch(() => undefined);
    await file?.close().catch(() => undefined);
    if (temporary) await remove(temporary).catch(() => undefined);
  }
};
const fetchSong: CacheApi["song"]["fetch"] = (key, source, url) => {
  if (
    clearing ||
    !store.get("cache.songCache.enabled") ||
    source === "local" ||
    (source === "streaming" && !store.get("cache.songCache.cacheStreaming"))
  )
    return Promise.resolve(null);
  if (active) return active.key === key ? active.promise : Promise.resolve(null);
  const controller = new AbortController();
  const promise = download(key, url, controller).finally(() => {
    active = undefined;
  });
  active = { key, controller, promise };
  return promise;
};
const clear: CacheApi["clear"] = async (id) => {
  if (Object.hasOwn(prefixes, id)) {
    clearLyricStorage(prefixes[id]);
    return;
  }
  if (id !== "songs") throw new Error("Unknown cache category");
  clearing++;
  try {
    active?.controller.abort();
    await active?.promise;
    await exclusive(async () => {
      await initialize();
      const root = await getDir();
      for (const file of await readDir(root)) {
        if (file.isFile && !file.isSymlink) await remove(await join(root, file.name));
      }
      entries = [];
      protectedName = undefined;
      await save();
    });
  } finally {
    clearing--;
  }
};
export const mobileCache: CacheApi = {
  getDir,
  pickDir: async () => ({ ok: false, dir: await getDir(), reason: "canceled" }),
  resetDir: getDir,
  clear,
  clearAllByKind: async (kind) => {
    for (const id of kind === "file" ? ["songs"] : Object.keys(prefixes)) await clear(id);
  },
  getStats: async () =>
    exclusive(async () => {
      await initialize();
      for (const entry of [...entries]) {
        const path = await join(await getDir(), entry.name);
        if (!(await exists(path)) || (await stat(path)).size !== entry.size) {
          entries.splice(entries.indexOf(entry), 1);
          if (entry.name === protectedName) protectedName = undefined;
        }
      }
      await trim();
      const result: Awaited<ReturnType<CacheApi["getStats"]>> = [
        {
          id: "songs",
          kind: "file",
          path: await getDir(),
          size: entries.reduce((sum, entry) => sum + entry.size, 0),
        },
      ];
      for (const [id, prefix] of Object.entries(prefixes)) {
        let size = 0;
        for (let i = 0; i < localStorage.length; i++) {
          const key = localStorage.key(i);
          if (key?.startsWith(prefix))
            size += (key.length + (localStorage.getItem(key)?.length ?? 0)) * 2;
        }
        result.push({ id, kind: "db", path: "", size });
      }
      return result;
    }),
  song: {
    lookup,
    fetch: fetchSong,
    cancel: async (key) => {
      if (active?.key === key) {
        active.controller.abort();
        await active.promise;
      }
    },
  },
};
