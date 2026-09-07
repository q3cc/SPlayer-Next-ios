import type { Track } from "@shared/types/player";
import type { Platform } from "@shared/types/platform";
import type { SiriSearchResult } from "@shared/types/siri";
import { normalizeSiriText, scoreSiriTracks } from "./searchMatching";

/** 保留标题里的版本标记；未知歌手不跨平台合并。 */
export const siriSongKey = (track: Track): string =>
  JSON.stringify([
    normalizeSiriText(track.title),
    track.artists.length
      ? [...new Set(track.artists.map((artist) => normalizeSiriText(artist.name)))].sort()
      : [`${track.source}:${track.id}`],
  ]);

/** 先选歌曲，再选音源；平台会员不能提高另一首同名歌曲的相关性。 */
export const mergeSiriResults = (
  pages: Track[][],
  query: string,
  artist: string,
  source: Platform,
  vipSources: Platform[] = [],
): SiriSearchResult => {
  const candidates = pages.flat();
  const scores = new Map(
    scoreSiriTracks(candidates, query, artist).map((item) => [item.track, item.score]),
  );
  const groups = new Map<
    string,
    { key: string; tracks: Track[]; quality: number; ranks: Map<string, number> }
  >();
  for (const page of pages)
    page.forEach((track, index) => {
      const quality = scores.get(track);
      if (quality == null) return;
      const key = siriSongKey(track);
      const group = groups.get(key) ?? {
        key,
        tracks: [],
        quality,
        ranks: new Map<string, number>(),
      };
      if (!group.tracks.some((item) => item.source === track.source && item.id === track.id))
        group.tracks.push(track);
      group.ranks.set(track.source, Math.min(group.ranks.get(track.source) ?? Infinity, index + 1));
      groups.set(key, group);
    });
  const ranked = [...groups.values()]
    .map((group) => ({
      ...group,
      score: [...group.ranks.values()].reduce((sum, rank) => sum + 1 / (10 + rank), 0),
    }))
    .sort((a, b) => b.quality - a.quality || b.score - a.score || a.key.localeCompare(b.key));
  for (const group of ranked)
    group.tracks.sort(
      (a, b) =>
        Number(b.source === "local") - Number(a.source === "local") ||
        Number(vipSources.includes(b.source as Platform)) -
          Number(vipSources.includes(a.source as Platform)) ||
        Number(b.source === source) - Number(a.source === source),
    );
  const [first, second] = ranked;
  const topFive = first
    ? [...first.ranks.entries()].filter(([platform, rank]) => platform !== "local" && rank <= 5)
        .length
    : 0;
  const certain =
    !!first &&
    first.quality === 100 &&
    (!second || second.quality < 100 || (topFive >= 2 && first.score >= second.score * 1.2));
  return {
    tracks: ranked.map((group) => group.tracks[0]),
    groups: ranked.map(({ key, tracks }) => ({ key, tracks })),
    needsConfirmation: ranked.length > 1 && !certain,
  };
};
