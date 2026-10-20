import type { Track } from "../types/player";
import { neteaseCdnUrl } from "./neteaseCdnUrl";

/** 大封面使用来源提供的原图；只移除已知网易云 CDN 的缩放参数，不改签名地址。 */
export const originalArtwork = (track: Track): string => {
  const candidate =
    track.source === "netease"
      ? neteaseCdnUrl(track.coverOriginal || track.cover || "")
      : track.coverOriginal || track.cover || "";
  if (track.source !== "netease" || !candidate) return candidate;
  try {
    const url = new URL(candidate);
    if (/^https?:$/.test(url.protocol) && /(^|\.)music\.126\.net$/.test(url.hostname)) {
      url.searchParams.delete("param");
      return url.href;
    }
  } catch {
    // 本地封面和非 URL 地址保持原样。
  }
  return candidate;
};
