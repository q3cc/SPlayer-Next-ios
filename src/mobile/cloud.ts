import { open as pickFiles } from "@tauri-apps/plugin-dialog";
import { open, stat, SeekMode } from "@tauri-apps/plugin-fs";
import { invoke } from "@tauri-apps/api/core";
import { mobileProviders } from "./providers";
import { fetchWithProxy } from "./shims/proxy";
import { AUDIO_EXTENSIONS } from "@shared/types/cloudUpload";
import type { CloudUploadApi, CloudUploadProgress, PickedSong } from "@shared/types/cloudUpload";

const BUCKET = "jd-musicrep-privatecloud-audio-public";
const listeners = new Set<(value: CloudUploadProgress) => void>();
interface CloudResponse {
  code: number;
  needUpload?: boolean;
  songId?: string | number;
  data?: { songId?: string | number }[];
  result?: { token?: string; objectKey?: string; resourceId?: string | number };
}

/** 校验业务状态，避免登录过期或服务端拒绝被当作秒传成功。 */
const call = async (name: string, params: Record<string, unknown>) => {
  const response = await mobileProviders.call("netease", name, params);
  const body = response.body as CloudResponse | undefined;
  if (!response.ok || response.status !== 200 || body?.code !== 200) {
    throw new Error("云盘请求失败：" + (body?.code ?? response.status ?? "network"));
  }
  return body;
};

export const mobileCloud: CloudUploadApi = {
  pickSongs: async () => {
    const paths = await pickFiles({
      multiple: true,
      directory: false,
      fileAccessMode: "copy",
      filters: [{ name: "Audio", extensions: AUDIO_EXTENSIONS }],
    });
    if (!paths) return [];
    const songs: PickedSong[] = [];
    for (const path of Array.isArray(paths) ? paths : [paths]) {
      const name = path.replaceAll("\\", "/").split("/").pop() ?? path;
      if (!AUDIO_EXTENSIONS.includes(name.split(".").pop()?.toLowerCase() ?? "")) continue;
      const info = await stat(path);
      if (info.isFile && info.size > 0) songs.push({ path, name, size: info.size });
    }
    return songs;
  },
  uploadSong: async (path, uploadId) => {
    const total = (await stat(path)).size;
    if (!total) throw new Error("不能上传空文件");
    const name = path.replaceAll("\\", "/").split("/").pop()!;
    const ext = name.split(".").pop()!.toLowerCase();
    if (!AUDIO_EXTENSIONS.includes(ext)) throw new Error("不支持的音频格式");
    const progress = (stage: CloudUploadProgress["stage"], loaded: number) => {
      for (const listener of listeners) listener({ uploadId, stage, loaded, total });
    };
    const file = await open(path, { read: true });
    try {
      progress("checking", 0);
      // 原生文件分块读取，避免大体积无损歌曲在 WebView 中占用整文件内存。
      const buffer = new Uint8Array(1024 * 1024);
      const { createHash } = await import("node:crypto");
      const hash = createHash("md5");
      let size: number | null;
      while ((size = await file.read(buffer))) hash.update(buffer.subarray(0, size));
      const md5 = hash.digest("hex");
      const tags = await invoke<{ title?: string; artist?: string; album?: string }>(
        "plugin:native-audio|read_metadata",
        { source: path, autoPlay: false, trackId: null },
      ).catch(() => ({}) as { title?: string; artist?: string; album?: string });
      const metadata = {
        song: tags.title || name.replace(/\.[^.]+$/, ""),
        artist: tags.artist || "未知艺术家",
        album: tags.album || "未知专辑",
      };
      const check = await call("cloud_upload_check", { md5, length: total });
      if (check.needUpload === false) {
        progress("finishing", total);
        const match = (await call("cloud_upload_check_v2", { md5, fileSize: total })).data?.[0];
        if (!match?.songId) throw new Error("秒传查重失败");
        await call("cloud_song_import", { ...metadata, songId: match.songId, fileType: ext });
        return { success: true, instant: true, songId: String(match.songId) };
      }
      if (check.needUpload !== true || check.songId == null) throw new Error("云盘查重结果无效");
      const token = (
        await call("cloud_nos_token", {
          ext,
          filename: name
            .replace(/\.[^.]+$/, "")
            .replace(/\s/g, "")
            .replace(/\./g, "_"),
          md5,
        })
      ).result;
      if (!token?.token || !token.objectKey || !token.resourceId)
        throw new Error("获取上传凭证失败");
      const hostResponse = await fetchWithProxy(
        "https://wanproxy.127.net/lbs?version=1.0&bucketname=" + BUCKET,
        {
          signal: AbortSignal.timeout(10000),
        },
      );
      if (!hostResponse.ok) throw new Error("获取上传服务器失败");
      const host = ((await hostResponse.json()) as { upload?: string[] }).upload?.[0];
      if (!host) throw new Error("上传服务器为空");
      const base = new URL(host);
      if (base.protocol === "http:") base.protocol = "https:";
      if (base.protocol !== "https:") throw new Error("上传服务器必须使用 HTTPS");
      await file.seek(0, SeekMode.Start);
      let loaded = 0;
      let context: string | undefined;
      progress("uploading", loaded);
      while ((size = await file.read(buffer))) {
        const url = new URL(
          base.href.replace(/\/$/, "") + "/" + BUCKET + "/" + encodeURIComponent(token.objectKey),
        );
        url.search = new URLSearchParams({
          offset: String(loaded),
          complete: String(loaded + size === total),
          version: "1.0",
          ...(context ? { context } : {}),
        }).toString();
        const response = await fetchWithProxy(url, {
          method: "POST",
          headers: { "x-nos-token": token.token, "Content-Type": "application/octet-stream" },
          body: buffer.slice(0, size),
          signal: AbortSignal.timeout(300000),
        });
        if (!response.ok) throw new Error("上传失败：HTTP " + response.status);
        const result = (await response.json()) as { offset?: number; context?: string };
        if (result.offset !== loaded + size) throw new Error("上传字节数不一致");
        loaded = result.offset;
        context = result.context;
        if (loaded < total && !context) throw new Error("上传续传凭证缺失");
        progress("uploading", loaded);
      }
      if (loaded !== total) throw new Error("上传期间文件发生变化");
      progress("finishing", total);
      const info = await call("cloud_upload_info", {
        ...metadata,
        md5,
        songid: check.songId,
        filename: name,
        resourceId: token.resourceId,
      });
      if (info.songId == null) throw new Error("提交歌曲信息失败");
      await call("cloud_pub", { songid: info.songId });
      return { success: true, instant: false, songId: String(info.songId) };
    } finally {
      await file.close();
    }
  },
  onUploadProgress: (listener) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
};
