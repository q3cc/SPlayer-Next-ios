import { mobileProviders } from "../providers";
import { searchSongs } from "@/apis/search";
import { resolveNeteaseUrl } from "@/apis/song/netease";
import { resolveQQMusicUrl } from "@/apis/song/qqmusic";
import { resolveKugouUrl } from "@/apis/song/kugou";
import type { Track } from "@shared/types/player";
import type { Platform } from "@shared/types/platform";
import type { QualityLevel } from "@/utils/quality";

interface Request {
  action: "search" | "resolve";
  query?: string;
  artist?: string;
  source: Platform;
  scope: "local" | "localFirst" | "online";
  library: Track[];
  track?: Track;
  allowTrial: boolean;
  quality: QualityLevel;
}

const normalize = (text: string): string =>
  text
    .normalize("NFKC")
    .toLocaleLowerCase()
    .replace(/[\s·・—_-]/g, "");

/** 同一套平台搜索、加密、登录态和试听解析，在 JavaScriptCore 中执行。 */
export const run = async (request: Request): Promise<unknown> => {
  window.api = { apis: mobileProviders } as Window["api"];
  if (request.action === "search") {
    const query = normalize(request.query ?? "");
    const artist = normalize(request.artist ?? "");
    if (!query && !artist) throw new Error("请说出歌名或歌手");
    const matches = (track: Track): boolean =>
      (!query || normalize(track.title).includes(query)) &&
      (!artist || track.artists.some((item) => normalize(item.name).includes(artist)));
    const local = request.scope === "online" ? [] : request.library.filter(matches).slice(0, 10);
    if (local.length || request.scope === "local") return { tracks: local };
    const result = await searchSongs(
      request.source,
      [request.query, request.artist].filter(Boolean).join(" "),
      0,
      20,
    );
    return { tracks: result.items.filter(matches).slice(0, 10) };
  }
  const track = request.track;
  if (!track) throw new Error("没有可播放的歌曲");
  if (track.source === "local" && track.path) return { url: track.path, isTrial: false };
  const result =
    track.source === "netease"
      ? await resolveNeteaseUrl(track, request.quality)
      : track.source === "qqmusic"
        ? await resolveQQMusicUrl(track, request.quality, request.allowTrial)
        : track.source === "kugou"
          ? await resolveKugouUrl(track, request.quality, request.allowTrial)
          : null;
  if (!result?.available) throw new Error(result?.errorCode ?? "该音乐来源尚不支持 Siri");
  if (result.isTrial && !request.allowTrial)
    throw new Error("该歌曲只能试听，请先在播放器设置中允许试听");
  return { url: result.url, isTrial: result.isTrial };
};
