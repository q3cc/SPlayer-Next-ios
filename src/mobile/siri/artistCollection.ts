import { searchArtists, searchSongs } from "@/apis/search";
import { fetchArtistSongs } from "@/apis/artist/netease";
import { fetchQQMusicArtistSongs } from "@/apis/artist/qqmusic";
import { ALL_PLATFORMS, type Platform } from "@shared/types/platform";
import type { Track } from "@shared/types/player";
import type { SiriArtistCollection, SiriSearchResult } from "@shared/types/siri";
import { normalizeSiriText } from "./searchMatching";
import { mergeSiriResults } from "./ranking";

/** 每次只拉一页，原生播放器负责播放后继续补页和持久化游标。 */
export const loadSiriArtistPage = async (
  artist: string,
  options: {
    source: Platform;
    scope: string;
    library: Track[];
    vipSources?: Platform[];
    collection?: SiriArtistCollection;
  },
): Promise<SiriSearchResult> => {
  const collection: SiriArtistCollection = options.collection
    ? {
        ...options.collection,
        cursors: options.collection.cursors.map((cursor) => ({ ...cursor })),
      }
    : {
        artist,
        cursors:
          options.scope === "local"
            ? []
            : ALL_PLATFORMS.map((source) => ({ source, offset: 0, done: false })),
        seen: [],
      };
  const local =
    options.collection || options.scope === "online"
      ? []
      : options.library.filter((track) =>
          track.artists.some((item) => normalizeSiriText(item.name) === normalizeSiriText(artist)),
        );
  // 优先本地时不等网络，先返回本地队列；下一页才查询在线平台。
  let pageFailed = false;
  const pages = local.length
    ? []
    : await Promise.all(
        collection.cursors.map(async (cursor) => {
          if (cursor.done) return [];
          try {
            if (cursor.source !== "kugou" && !cursor.artistId) {
              const result = await searchArtists(cursor.source, artist, 0, 20);
              const matches = result.items.filter(
                (item) => normalizeSiriText(item.title) === normalizeSiriText(artist),
              );
              // 作品量只是热度代理，不伪称官方热度；信息缺失或相同时保留平台排名。
              matches.sort(
                (a, b) =>
                  Math.log1p(b.artistSongCount ?? 0) +
                  2 * Math.log1p(b.artistAlbumCount ?? 0) -
                  (Math.log1p(a.artistSongCount ?? 0) + 2 * Math.log1p(a.artistAlbumCount ?? 0)),
              );
              if (!matches.length) {
                cursor.done = true;
                return [];
              }
              cursor.artistId = matches[0].id;
            }
            const result =
              cursor.source === "netease"
                ? await fetchArtistSongs(cursor.artistId!, cursor.offset, 50)
                : cursor.source === "qqmusic"
                  ? await fetchQQMusicArtistSongs(cursor.artistId!, cursor.offset, 50)
                  : await searchSongs("kugou", artist, cursor.offset, 50).then((page) => ({
                      tracks: page.items,
                      more: page.hasMore,
                    }));
            const signature = result.tracks.map((track) => `${track.source}:${track.id}`).join("|");
            if (signature === cursor.lastPage && signature) {
              pageFailed = true;
              return [];
            }
            cursor.lastPage = signature;
            cursor.offset += result.tracks.length;
            cursor.done = !result.more || !result.tracks.length;
            return result.tracks.filter((track) =>
              track.artists.some(
                (item) =>
                  normalizeSiriText(item.name) === normalizeSiriText(artist) &&
                  (!cursor.artistId || !item.id || String(item.id) === cursor.artistId),
              ),
            );
          } catch (error) {
            pageFailed = true;
            console.warn("[siri] 歌手曲库分页失败", cursor.source, String(error));
            return [];
          }
        }),
      );
  const merged = mergeSiriResults(
    [local, ...pages],
    "",
    artist,
    options.source,
    options.vipSources,
  );
  const seen = new Set(collection.seen);
  const groups = merged.groups.filter((group) => !seen.has(group.key));
  collection.seen = [...seen, ...groups.map((group) => group.key)];
  return {
    tracks: groups.map((group) => group.tracks[0]),
    groups,
    collection,
    needsConfirmation: false,
    pageFailed,
  };
};
