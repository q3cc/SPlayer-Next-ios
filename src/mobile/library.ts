import { convertFileSrc, invoke, isTauri } from "@tauri-apps/api/core";
import { join } from "@tauri-apps/api/path";
import { open } from "@tauri-apps/plugin-dialog";
import { readDir, remove, stat } from "@tauri-apps/plugin-fs";
import type { AlbumSummary, ArtistSummary, LibraryApi, ScanProgress } from "@shared/types/library";
import type { Track } from "@shared/types/player";

const TRACKS_STORAGE_KEY = "splayer.mobile.library";
const DIRECTORIES_STORAGE_KEY = "splayer.mobile.scanDirs";
const AUDIO_EXTENSIONS = new Set(["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "ape"]);
const listeners = new Set<(progress: ScanProgress) => void>();

const readJson = <T>(key: string, fallback: T): T => {
  try {
    return JSON.parse(localStorage.getItem(key) ?? "") as T;
  } catch {
    return fallback;
  }
};

let tracks = readJson<Track[]>(TRACKS_STORAGE_KEY, []);
let scanDirs = readJson<string[]>(DIRECTORIES_STORAGE_KEY, []);

const persist = (): void => {
  localStorage.setItem(TRACKS_STORAGE_KEY, JSON.stringify(tracks));
  localStorage.setItem(DIRECTORIES_STORAGE_KEY, JSON.stringify(scanDirs));
  window.dispatchEvent(new Event("splayer:siri-data-changed"));
};
const success = <T>(data?: T) => ({ success: true as const, data });
const announce = (progress: ScanProgress): void =>
  listeners.forEach((listener) => listener(progress));

const pathName = (path: string): string => decodeURIComponent(path.split("/").pop() ?? path);
const withoutExtension = (name: string): string => name.replace(/\.[^.]+$/, "");
const extensionOf = (path: string): string => path.split(".").pop()?.toLocaleLowerCase() ?? "";
const idFor = (path: string): string => {
  let hash = 2166136261;
  for (let index = 0; index < path.length; index += 1) {
    hash = Math.imul(hash ^ path.charCodeAt(index), 16777619);
  }
  return `mobile-${(hash >>> 0).toString(16)}`;
};

const childPath = async (parent: string, name: string): Promise<string> => {
  if (parent.startsWith("file:")) {
    const base = parent.endsWith("/") ? parent : `${parent}/`;
    return new URL(encodeURIComponent(name), base).toString();
  }
  return join(parent, name);
};

const listAudioFiles = async (root: string): Promise<string[]> => {
  const files: string[] = [];
  const pending = [root];
  while (pending.length) {
    const current = pending.pop();
    if (!current) continue;
    for (const entry of await readDir(current)) {
      const path = await childPath(current, entry.name);
      if (entry.isDirectory) pending.push(path);
      else if (entry.isFile && AUDIO_EXTENSIONS.has(extensionOf(entry.name))) files.push(path);
    }
  }
  return files;
};

const trackFromFile = async (path: string): Promise<Track> => {
  const info = await stat(path);
  const tags = isTauri()
    ? await invoke<{ title?: string; artist?: string; album?: string; duration?: number }>(
        "plugin:native-audio|read_metadata",
        { source: path, autoPlay: false },
      ).catch(() => ({}) as { title?: string; artist?: string; album?: string; duration?: number })
    : {};
  const fallbackTime = Date.now();
  return {
    id: idFor(path),
    source: "local",
    path,
    title: tags.title || withoutExtension(pathName(path)),
    artists: [{ name: tags.artist || "Unknown Artist" }],
    album: tags.album ? { name: tags.album } : undefined,
    duration: tags.duration ?? 0,
    fileSize: info.size,
    mtime: info.mtime?.getTime() ?? fallbackTime,
    ctime: info.birthtime?.getTime() ?? fallbackTime,
  };
};

/**
 * 扫描移动端系统目录并转换为公共曲目结构
 * @param directories - 系统文件选择器返回的目录
 * @returns 可直接交给公共曲库 store 的曲目
 */
export const scanMobileDirectories = async (directories: readonly string[]): Promise<Track[]> => {
  const paths = (await Promise.all(directories.map(listAudioFiles))).flat();
  const next: Track[] = [];
  announce({ phase: "scanning", total: paths.length, scanned: 0 });
  for (const [index, path] of paths.entries()) {
    next.push(await trackFromFile(path));
    announce({
      phase: "scanning",
      total: paths.length,
      scanned: index + 1,
      current: pathName(path),
    });
  }
  return next;
};

const scanDirectories = async (): Promise<void> => {
  tracks = await scanMobileDirectories(scanDirs);
  persist();
  announce({ phase: "done", total: tracks.length, scanned: tracks.length });
};

const isWithin = (path: string, directory: string): boolean => {
  const prefix = directory.endsWith("/") ? directory : `${directory}/`;
  return path === directory || path.startsWith(prefix);
};

export const resolveMobileAudioSource = (source: string): string => {
  if (source.startsWith("file:")) {
    return convertFileSrc(decodeURIComponent(new URL(source).pathname));
  }
  if (/^(https?|blob|data|asset):/i.test(source)) return source;
  return convertFileSrc(source);
};

export const getMobileTrack = (id: string): Track | undefined =>
  tracks.find((track) => track.id === id);

export const mobileLibrary: LibraryApi = {
  scan: async () => {
    try {
      await scanDirectories();
      return success();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      announce({ phase: "error", total: 0, scanned: 0, error: message });
      return { success: false, error: message };
    }
  },
  cancelScan: async () => success(),
  getTracks: async () => success(tracks),
  getAlbums: async () => {
    const groups = new Map<string, AlbumSummary>();
    for (const track of tracks) {
      const name = track.album?.name || "Unknown Album";
      const item = groups.get(name) ?? {
        name,
        artist: track.album?.artist || track.artists.map((artist) => artist.name).join(" / "),
        cover: track.cover,
        trackCount: 0,
      };
      item.trackCount++;
      groups.set(name, item);
    }
    return success([...groups.values()]);
  },
  getArtists: async () => {
    const groups = new Map<string, ArtistSummary>();
    for (const track of tracks) {
      for (const artist of track.artists) {
        const item = groups.get(artist.name) ?? {
          name: artist.name,
          cover: track.cover,
          trackCount: 0,
        };
        item.trackCount++;
        groups.set(artist.name, item);
      }
    }
    return success([...groups.values()]);
  },
  getAlbumTracks: async (name) => success(tracks.filter((track) => track.album?.name === name)),
  getArtistTracks: async (name) =>
    success(tracks.filter((track) => track.artists.some((artist) => artist.name === name))),
  getTracksByIds: async (ids) => {
    const wanted = new Set(ids);
    return success(tracks.filter((track) => wanted.has(track.id)));
  },
  searchTracks: async (query) => {
    const normalized = query.trim().toLocaleLowerCase();
    return success(
      tracks.filter((track) =>
        [track.title, track.album?.name, ...track.artists.map((artist) => artist.name)].some(
          (value) => value?.toLocaleLowerCase().includes(normalized),
        ),
      ),
    );
  },
  getTrackCount: async () => success(tracks.length),
  getRandomTrack: async () =>
    success(tracks.length ? tracks[Math.floor(Math.random() * tracks.length)] : null),
  getRandomTracks: async (limit) =>
    success([...tracks].sort(() => Math.random() - 0.5).slice(0, limit)),
  isScanning: async () => success(false),
  addScanDir: async () => {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
        recursive: true,
        fileAccessMode: "copy",
      });
      if (!selected) return { success: false, error: "canceled" };
      if (!scanDirs.includes(selected)) {
        scanDirs = [...scanDirs, selected];
        persist();
      }
      return success(selected);
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) };
    }
  },
  removeScanDir: async (directory) => {
    scanDirs = scanDirs.filter((item) => item !== directory);
    tracks = tracks.filter((track) => !track.path || !isWithin(track.path, directory));
    persist();
    return success();
  },
  getScanDirs: async () => success(scanDirs),
  deleteTracks: async (paths) => {
    let deleted = 0;
    for (const path of paths) {
      try {
        await remove(path);
        deleted += 1;
      } catch {}
    }
    const deletedPaths = new Set(paths);
    tracks = tracks.filter((track) => !track.path || !deletedPaths.has(track.path));
    persist();
    return success({ deleted, failed: paths.length - deleted });
  },
  readTags: async () => ({ success: false, error: "tag editing is not available on mobile" }),
  writeTags: async () => ({ success: false, error: "tag editing is not available on mobile" }),
  pickCoverImage: async () => ({
    success: false,
    error: "cover picking is not available on mobile",
  }),
  fetchArtistAvatar: async () => success(null),
  prefetchArtistAvatars: async () => success({}),
  onScanProgress: (callback) => {
    listeners.add(callback);
    return () => listeners.delete(callback);
  },
};
