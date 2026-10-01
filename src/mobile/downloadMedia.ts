import localforage from "localforage";
import { documentDir, join } from "@tauri-apps/api/path";
import { exists, open, readTextFile, remove, rename, writeTextFile } from "@tauri-apps/plugin-fs";
import type { DownloadRequest } from "@shared/types/download";
import type { Track } from "@shared/types/player";
import type { LyricFormat } from "@shared/types/lyrics";
import { neteaseCdnUrl } from "@shared/utils/neteaseCdnUrl";
import { fetchWithProxy } from "./shims/proxy";

const index = localforage.createInstance({ name: "splayer", storeName: "download-media" });
const MAX_COVER_BYTES = 8 * 1024 * 1024;

interface MediaRecord {
  track: Track;
  cover?: string;
  lyrics: { format: LyricFormat; path: string }[];
}

export interface DownloadMedia {
  audioPath: string;
  track: Track;
  coverPath?: string;
  externalLyrics: { format: LyricFormat; path: string }[];
}

const identity = (track: Track): string =>
  JSON.stringify([track.source, track.serverId ?? "", track.originalId ?? track.id]);
const rootDirectory = async (): Promise<string> => join(await documentDir(), "Downloads");
const relativePath = (root: string, path: string): string | null =>
  path.startsWith(root + "/") ? path.slice(root.length + 1) : null;
const restorePath = async (root: string, path: string): Promise<string | null> =>
  path && !path.startsWith("/") && !path.includes("\\") && !path.split("/").includes("..")
    ? join(root, path)
    : null;

/** 原生媒体卡片使用文件 URL，应用内图片继续通过 Tauri 的资源协议读取。 */
export const downloadFileUrl = (path: string): string =>
  `file://${path.split("/").map(encodeURIComponent).join("/")}`;

/** 下载附属文件只存相对路径，iOS 更新后的沙盒变化不影响离线播放。 */
export const readDownloadMedia = async (source: string): Promise<DownloadMedia | null> => {
  const root = await rootDirectory();
  const path = source.startsWith("file:") ? decodeURIComponent(new URL(source).pathname) : source;
  if (!relativePath(root, path)) return null;
  try {
    if (!(await exists(path))) return null;
    const record = JSON.parse(await readTextFile(path + ".splayer.json")) as MediaRecord;
    const coverPath = record.cover ? await restorePath(root, record.cover) : null;
    const externalLyrics: DownloadMedia["externalLyrics"] = [];
    for (const lyric of record.lyrics) {
      const lyricPath = await restorePath(root, lyric.path);
      if (lyricPath && (await exists(lyricPath)))
        externalLyrics.push({ format: lyric.format, path: lyricPath });
    }
    return {
      audioPath: path,
      track: record.track,
      coverPath: coverPath && (await exists(coverPath)) ? coverPath : undefined,
      externalLyrics,
    };
  } catch {
    return null;
  }
};

/** 按原始歌曲身份查找下载，不受临时缓存开关、音质设置或下载历史清理影响。 */
export const findDownloadMedia = async (track: Track): Promise<DownloadMedia | null> => {
  if (track.source === "local") return track.path ? readDownloadMedia(track.path) : null;
  const paths = (await index.getItem<string[]>(identity(track))) ?? [];
  const root = await rootDirectory();
  for (const relative of [...paths].reverse()) {
    const path = await restorePath(root, relative);
    const media = path ? await readDownloadMedia(path) : null;
    if (media && identity(media.track) === identity(track)) return media;
  }
  return null;
};

/** 逐块写入封面并限制体积，避免下载原图时让整张图片常驻 JS 内存。 */
const saveCover = async (url: string, stem: string): Promise<string> => {
  const response = await fetchWithProxy(neteaseCdnUrl(url));
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    throw new Error("invalid cover response");
  }
  const mime = response.headers.get("content-type")?.split(";")[0];
  const byMime = (
    { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" } as Record<string, string>
  )[mime ?? ""];
  const reader = response.body.getReader();
  const first = await reader.read();
  if (first.done || !first.value.length) {
    await reader.cancel();
    throw new Error("empty cover");
  }
  const bytes = first.value;
  const signature =
    bytes[0] === 0xff && bytes[1] === 0xd8
      ? "jpg"
      : bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
        ? "png"
        : String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" &&
            String.fromCharCode(...bytes.slice(8, 12)) === "WEBP"
          ? "webp"
          : null;
  const extension = byMime || signature;
  if (!extension) {
    await reader.cancel();
    throw new Error("invalid cover response");
  }
  const target = stem + ".cover." + extension;
  const temporary = target + ".part";
  let file: Awaited<ReturnType<typeof open>> | undefined;
  let size = 0;
  try {
    file = await open(temporary, { write: true, create: true, truncate: true });
    let chunk: ReadableStreamReadResult<Uint8Array> = first;
    while (true) {
      if (chunk.done) break;
      size += chunk.value.length;
      if (size > MAX_COVER_BYTES) throw new Error("cover too large");
      let offset = 0;
      while (offset < chunk.value.length) {
        const written = await file.write(chunk.value.subarray(offset));
        if (written <= 0) throw new Error("cover write failed");
        offset += written;
      }
      chunk = await reader.read();
    }
    if (!size) throw new Error("empty cover");
    await file.close();
    file = undefined;
    await rename(temporary, target);
    return target;
  } finally {
    await reader.cancel().catch(() => undefined);
    await file?.close().catch(() => undefined);
    if (await exists(temporary)) await remove(temporary);
  }
};

/** 音频落盘后保存封面及完整歌词；附属资源失败不删除已下载的歌曲。 */
export const saveDownloadMedia = async (
  request: DownloadRequest,
  audioPath: string,
): Promise<boolean> => {
  const root = await rootDirectory();
  const relativeAudio = relativePath(root, audioPath);
  if (!relativeAudio) throw new Error("download outside Downloads");
  const previous = await readDownloadMedia(audioPath);
  if (!previous) await remove(audioPath + ".splayer.json").catch(() => undefined);
  const sameTrack = previous && identity(previous.track) === identity(request.track);
  // 保留音频扩展名，避免不同音质同名文件共享附属资源，删除时误伤另一份下载。
  const stem = audioPath;
  const { id, source, title, artists, album, duration, serverId, originalId } = request.track;
  const record: MediaRecord = {
    track: { id, source, title, artists, album, duration, serverId, originalId },
    cover: sameTrack && previous?.coverPath ? relativePath(root, previous.coverPath)! : undefined,
    lyrics: sameTrack
      ? previous.externalLyrics.map((lyric) => ({
          format: lyric.format,
          path: relativePath(root, lyric.path)!,
        }))
      : [],
  };
  let warning = false;
  const coverUrl = request.track.cover || request.coverUrl || request.track.coverOriginal;
  if (coverUrl) {
    try {
      record.cover = relativePath(root, await saveCover(coverUrl, stem))!;
    } catch (error) {
      warning = true;
      console.warn("[download] 下载封面保存失败", error);
    }
  }
  try {
    let { lyricText, ttmlText } = request;
    if (!lyricText && !ttmlText) {
      const { resolveDownloadLyric } = await import("@/services/download/lyric");
      const { buildDownloadLyric } = await import("@/utils/lyric/serialize");
      const lyric = await resolveDownloadLyric(request.track);
      if (lyric) {
        lyricText = buildDownloadLyric(lyric, lyric.format, request.lyricFileFormat) ?? undefined;
        ttmlText = buildDownloadLyric(lyric, lyric.format, "ttml") ?? undefined;
      }
    }
    for (const [format, text] of [
      ["lrc", lyricText],
      ["ttml", ttmlText],
    ] as const) {
      if (!text?.trim()) continue;
      const path = stem + "." + format;
      await writeTextFile(path, text);
      record.lyrics = [
        ...record.lyrics.filter((lyric) => lyric.format !== format),
        { format, path: relativePath(root, path)! },
      ];
    }
  } catch (error) {
    warning = true;
    console.warn("[download] 下载歌词保存失败", error);
  }
  const metadataPart = audioPath + ".splayer.json.part";
  try {
    await writeTextFile(metadataPart, JSON.stringify(record));
    await rename(metadataPart, audioPath + ".splayer.json");
  } finally {
    if (await exists(metadataPart)) await remove(metadataPart);
  }
  if (previous && identity(previous.track) !== identity(request.track)) {
    const oldPaths = (await index.getItem<string[]>(identity(previous.track))) ?? [];
    await index.setItem(
      identity(previous.track),
      oldPaths.filter((path) => path !== relativeAudio),
    );
  }
  const paths = (await index.getItem<string[]>(identity(request.track))) ?? [];
  await index.setItem(identity(request.track), [
    ...paths.filter((path) => path !== relativeAudio),
    relativeAudio,
  ]);
  if (previous) {
    const retained = new Set([record.cover, ...record.lyrics.map((lyric) => lyric.path)]);
    for (const path of [
      previous.coverPath,
      ...previous.externalLyrics.map((lyric) => lyric.path),
    ]) {
      if (path && !retained.has(relativePath(root, path) ?? undefined))
        await remove(path).catch(() => undefined);
    }
  }
  return warning;
};

/** 删除歌曲时一起移除下载附属文件；清空历史记录不会调用此方法。 */
export const removeDownloadMedia = async (audioPath: string): Promise<void> => {
  const media = await readDownloadMedia(audioPath);
  await remove(audioPath);
  if (!media) return;
  const root = await rootDirectory();
  for (const path of [media.coverPath, ...media.externalLyrics.map((lyric) => lyric.path)]) {
    if (path) await remove(path);
  }
  await remove(audioPath + ".splayer.json");
  const key = identity(media.track);
  const paths = (await index.getItem<string[]>(key)) ?? [];
  const next = paths.filter((path) => path !== relativePath(root, audioPath));
  if (next.length) await index.setItem(key, next);
  else await index.removeItem(key);
};
