import { mobileProviders } from "../providers";
import { searchSongs } from "@/apis/search";
import { resolveNeteaseUrl } from "@/apis/song/netease";
import { resolveQQMusicUrl } from "@/apis/song/qqmusic";
import { resolveKugouUrl } from "@/apis/song/kugou";
import type { Track } from "@shared/types/player";
import type { Platform } from "@shared/types/platform";
import { ALL_PLATFORMS } from "@shared/types/platform";
import type { QualityLevel } from "@/utils/quality";
import { siriCollectionArtist } from "./searchMatching";
import { mergeSiriResults } from "./ranking";
import { loadSiriArtistPage } from "./artistCollection";
import type { SiriArtistCollection, SiriSearchResult } from "@shared/types/siri";

interface Request {
  action: "search" | "resolve" | "artistPage";
  query?: string;
  artist?: string;
  source: Platform;
  scope: "local" | "localFirst" | "online";
  library: Track[];
  track?: Track;
  allowTrial: boolean;
  quality: QualityLevel;
  vipSources?: Platform[];
  collection?: SiriArtistCollection;
}

/** 同一套平台搜索、加密、登录态和试听解析，在 JavaScriptCore 中执行。 */
export const run = async (request: Request): Promise<unknown> => {
  window.api = { apis: mobileProviders } as Window["api"];
  if (request.action === "artistPage") {
    if (!request.collection) throw new Error("缺少歌手曲库游标");
    return loadSiriArtistPage(request.collection.artist, request);
  }
  if (request.action === "search") {
    const query = (request.query ?? "").trim();
    const artist = (request.artist ?? "").trim();
    if (!query && !artist) throw new Error("请说出歌名或歌手");
    const collectionArtist = siriCollectionArtist(query, artist);
    if (collectionArtist) return loadSiriArtistPage(collectionArtist, request);
    const local = mergeSiriResults(
      [request.scope === "online" ? [] : request.library],
      query,
      artist,
      request.source,
      request.vipSources,
    );
    if (local.tracks.length || request.scope === "local") return local;
    const sources = ALL_PLATFORMS;
    // 先保留完整歌名，不能把《特别的人》《我的天空》里的“的”删掉。
    const keyword = [query, artist].filter(Boolean).join(" ");
    const results = await Promise.allSettled(
      sources.map((source) => searchSongs(source, keyword, 0, 20)),
    );
    if (results.every((result) => result.status === "rejected"))
      throw new Error("三个音乐平台搜索均失败，请检查网络或登录状态");
    let ranked = mergeSiriResults(
      results.map((result) => (result.status === "fulfilled" ? result.value.items : [])),
      query,
      artist,
      request.source,
      request.vipSources,
    );
    const spoken = query.replace(/^(.+?)的(.+)$/u, "$1 $2");
    if (!ranked.tracks.length && spoken !== query && (!artist || query.startsWith(`${artist}的`))) {
      const retry = await Promise.allSettled(
        sources.map((source) => searchSongs(source, spoken, 0, 20)),
      );
      ranked = mergeSiriResults(
        retry.map((result) => (result.status === "fulfilled" ? result.value.items : [])),
        query,
        artist,
        request.source,
        request.vipSources,
      );
    }
    return { ...ranked, tracks: ranked.tracks.slice(0, 10), groups: ranked.groups.slice(0, 10) };
  }
  const track = request.track;
  if (!track) throw new Error("没有可播放的歌曲");
  if (track.source === "local" && track.path) return { url: track.path, isTrial: false };
  const resolve = async (track: Track) =>
    track.source === "netease"
      ? await resolveNeteaseUrl(track, request.quality)
      : track.source === "qqmusic"
        ? await resolveQQMusicUrl(track, request.quality, request.allowTrial)
        : track.source === "kugou"
          ? await resolveKugouUrl(track, request.quality, request.allowTrial)
          : null;
  let trial: { url: string; isTrial: boolean; track: Track } | undefined;
  const attempt = async (candidate: Track) => {
    try {
      const result = await resolve(candidate);
      if (!result?.available) return null;
      const playable = { url: result.url, isTrial: !!result.isTrial, track: candidate };
      if (!result.isTrial) return playable;
      if (request.allowTrial && !trial) trial = playable;
    } catch (error) {
      console.warn("[siri] 音源解析失败", candidate.source, String(error));
    }
    return null;
  };
  const selected = await attempt(track);
  if (selected) return selected;
  const alternatives = (await run({
    ...request,
    action: "search",
    scope: "online",
    query: track.title,
    artist: track.artists[0]?.name ?? "",
  }).catch(() => ({ tracks: [], groups: [] }))) as SiriSearchResult;
  // 换源不能悄悄改成翻唱、串烧或另一场现场版本。
  for (const candidate of alternatives.groups.flatMap((group) => group.tracks)) {
    if (
      candidate.source === track.source ||
      candidate.title.normalize("NFKC").trim().toLowerCase() !==
        track.title.normalize("NFKC").trim().toLowerCase() ||
      !track.artists.length ||
      !track.artists.every((artist) => candidate.artists.some((item) => item.name === artist.name))
    )
      continue;
    const playable = await attempt(candidate);
    if (playable) return playable;
  }
  if (trial) return trial;
  throw new Error("各平台均未获取到可播放链接，请检查会员权限或允许试听");
};
