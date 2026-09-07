import type { Track } from "@shared/types/player";

const normalize = (value: string): string =>
  value
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[\s·・—_-]/g, "");

/** 仅用歌手元数据确认口语中的歌手，避免把《我的天空》等歌名中的“的”强行拆开。 */
export const rankSiriTracks = (tracks: Track[], query: string, artist: string): Track[] => {
  let title = query.trim();
  let performer = artist.trim();
  const phrase = title.match(/^(.+?)(?:的|[_—]|\s+-\s+)(.+)$/u);
  if (phrase) {
    const prefix = normalize(phrase[1]);
    const knownArtist = tracks.some((track) =>
      track.artists.some((item) => normalize(item.name) === prefix),
    );
    if (performer ? normalize(performer) === prefix : knownArtist) {
      performer ||= phrase[1];
      title = phrase[2].trim();
      if (/^(?:歌|歌曲|音乐)$/.test(title)) title = "";
    }
  }
  const wantedTitle = normalize(title);
  const wantedArtist = normalize(performer);
  return tracks
    .map((track, index) => {
      // 标题中的人名、文件名和“某某翻唱”都不能证明实际演唱者符合请求。
      if (wantedArtist && !track.artists.some((item) => normalize(item.name) === wantedArtist))
        return { track, index, score: -1 };
      const actualTitle = normalize(track.title);
      let score = !wantedTitle || actualTitle === wantedTitle ? 100 : -1;
      if (score < 0 && wantedTitle) {
        const base = normalize(track.title.replace(/\s*[（([].*?[）)\]]\s*/gu, ""));
        if (base === wantedTitle) score = 80;
        else if (actualTitle.includes(wantedTitle)) score = 40;
      }
      return { track, index, score };
    })
    .filter(({ score }) => score >= 0)
    .sort((left, right) => right.score - left.score || left.index - right.index)
    .map(({ track }) => track);
};
