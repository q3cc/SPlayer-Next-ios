import { addPluginListener, invoke } from "@tauri-apps/api/core";
import { mobileProviders } from "./providers";
import { fetchWithProxy } from "./shims/proxy";
import type { CloudUploadApi, CloudUploadProgress } from "@shared/types/cloudUpload";
import { open } from "@tauri-apps/plugin-dialog";
import { stat } from "@tauri-apps/plugin-fs";
import { AUDIO_EXTENSIONS, type PickedSong } from "@shared/types/cloudUpload";

/** 调用 iOS 文件选择器，只读取所选音频的文件信息，不将音频载入内存。 */
export const pickCloudSongs = async (): Promise<PickedSong[]> => {
  const selected = await open({
    multiple: true,
    directory: false,
    filters: [{ name: "Audio", extensions: [...AUDIO_EXTENSIONS] }],
  });
  if (!selected) return [];
  const songs: PickedSong[] = [];
  for (const path of new Set(Array.isArray(selected) ? selected : [selected])) {
    const pathname = path.startsWith("file:") ? decodeURIComponent(new URL(path).pathname) : path;
    const name = pathname.split("/").pop() ?? "";
    const extension = name.split(".").pop()?.toLowerCase() ?? "";
    if (!AUDIO_EXTENSIONS.includes(extension)) continue;
    const info = await stat(path);
    if (info.isFile) songs.push({ path, name, size: info.size });
  }
  return songs;
};

const BUCKET = "jd-musicrep-privatecloud-audio-public";
const MIME_BY_EXT: Record<string, string> = {
  mp3: "audio/mpeg",
  flac: "audio/flac",
  wav: "audio/wav",
  m4a: "audio/mp4",
  aac: "audio/aac",
  ogg: "audio/ogg",
  opus: "audio/ogg",
  wma: "audio/x-ms-wma",
  ape: "audio/x-ape",
  aiff: "audio/aiff",
};
const listeners = new Set<(progress: CloudUploadProgress) => void>();
let uploading = false;

interface CloudBody {
  code: number;
  needUpload?: boolean | number;
  songId?: string | number;
  data?: { songId?: string | number; upload?: number }[];
  result?: { objectKey?: string; token?: string; resourceId?: string | number };
}

/** 网易返回业务失败时不能继续申请上传凭证或发布。 */
const callCloud = async (name: string, params: Record<string, unknown>): Promise<CloudBody> => {
  const response = await mobileProviders.call("netease", name, params);
  const body = response.body as CloudBody | undefined;
  if (!response.ok || body?.code !== 200) {
    const code = body?.code ?? response.status;
    throw new Error(typeof code === "number" ? "netease " + code : "cloud request failed");
  }
  return body;
};

/** 网易分配的 NOS 地址统一走 HTTPS，上传 token 不发送给其他域名。 */
export const cloudUploadURL = (host: string, objectKey: string): string => {
  const url = new URL(host);
  if (
    !["http:", "https:"].includes(url.protocol) ||
    !url.hostname.endsWith(".127.net") ||
    url.username ||
    url.password
  )
    throw new Error("invalid upload host");
  url.protocol = "https:";
  url.pathname = "/" + BUCKET + "/" + encodeURIComponent(objectKey);
  url.search = "?offset=0&complete=true&version=1.0";
  url.hash = "";
  return url.toString();
};

const uploadSong: CloudUploadApi["uploadSong"] = async (path, uploadId) => {
  if (uploading) return { success: false, instant: false };
  uploading = true;
  let subscription: Awaited<ReturnType<typeof addPluginListener>> | undefined;
  const emit = (stage: CloudUploadProgress["stage"], loaded: number, total: number): void =>
    listeners.forEach((listener) => listener({ uploadId, stage, loaded, total }));
  try {
    emit("checking", 0, 0);
    const { md5, size } = await invoke<{ md5: string; size: number }>(
      "plugin:native-audio|prepare_cloud_upload",
      { source: path },
    );
    if (!size || md5.length !== 32) throw new Error("invalid audio file");
    const pathname = path.startsWith("file:") ? decodeURIComponent(new URL(path).pathname) : path;
    const fullName = pathname.split("/").pop()!;
    const ext = fullName.split(".").pop()!.toLowerCase();
    const baseName = fullName.slice(0, -(ext.length + 1));
    const tags = await invoke<{ title?: string; artist?: string; album?: string }>(
      "plugin:native-audio|read_metadata",
      { source: path, autoPlay: false },
    ).catch(() => ({}) as { title?: string; artist?: string; album?: string });
    const song = tags.title || baseName;
    const artist = tags.artist || "未知艺术家";
    const album = tags.album || "未知专辑";
    const check = await callCloud("cloud_upload_check", { md5, length: size });
    if (![true, false, 0, 1].includes(check.needUpload!)) throw new Error("invalid upload check");
    if (!check.needUpload) {
      emit("finishing", size, size);
      const checked = await callCloud("cloud_upload_check_v2", { md5, fileSize: size });
      const matched = checked.data?.[0];
      if (!matched?.songId || matched.upload === 2) throw new Error("cloud import unavailable");
      if (matched.upload !== 1) {
        await callCloud("cloud_song_import", {
          songId: matched.songId,
          song,
          artist,
          album,
          fileType: ext,
        });
      }
      return { success: true, instant: true, songId: String(matched.songId) };
    }
    const granted = await callCloud("cloud_nos_token", {
      ext,
      filename: baseName.replace(/\s/g, "").replaceAll(".", "_"),
      md5,
    });
    const grant = granted.result;
    if (!grant?.objectKey || !grant.token || grant.resourceId == null)
      throw new Error("invalid upload token");
    const response = await fetchWithProxy(
      "https://wanproxy.127.net/lbs?version=1.0&bucketname=" + BUCKET,
      { signal: AbortSignal.timeout(10000) },
    );
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error("upload host unavailable");
    }
    const hosts = (await response.json()) as { upload?: string[] };
    if (!hosts.upload?.[0]) throw new Error("upload host unavailable");
    const url = cloudUploadURL(hosts.upload[0], grant.objectKey);
    subscription = await addPluginListener<CloudUploadProgress>(
      "native-audio",
      "cloudUploadProgress",
      (event) => {
        if (event.uploadId === uploadId) listeners.forEach((listener) => listener(event));
      },
    );
    emit("uploading", 0, size);
    await invoke("plugin:native-audio|upload_cloud_file", {
      source: path,
      uploadId,
      url,
      token: grant.token,
      md5,
      mime: MIME_BY_EXT[ext] ?? "audio/mpeg",
      size,
    });
    emit("finishing", size, size);
    const published = await callCloud("cloud_upload_info", {
      md5,
      songid: check.songId,
      filename: fullName,
      song,
      album,
      artist,
      resourceId: grant.resourceId,
    });
    if (published.songId == null) throw new Error("missing cloud song id");
    await callCloud("cloud_pub", { songid: published.songId });
    return { success: true, instant: false, songId: String(published.songId) };
  } catch (error) {
    const code =
      error instanceof Error && error.message.startsWith("netease ")
        ? Number(error.message.slice(8))
        : undefined;
    return {
      success: false,
      instant: false,
      errorCode: code && Number.isFinite(code) ? code : undefined,
    };
  } finally {
    await subscription?.unregister().catch(() => undefined);
    uploading = false;
  }
};

export const mobileCloud: CloudUploadApi = {
  pickSongs: pickCloudSongs,
  uploadSong,
  onUploadProgress: (callback) => {
    listeners.add(callback);
    return () => {
      listeners.delete(callback);
    };
  },
};
