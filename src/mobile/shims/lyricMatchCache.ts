import { clearLyricStorage, readLyricStorage, writeLyricStorage } from "./lyricStorage";
import { normalize, normalizeTrackArtists } from "@main/apis/common/lyric/utils";
import type { LyricMatchExtra } from "@shared/types/lyrics";
import type { Platform } from "@shared/types/platform";
import type { Track } from "@shared/types/player";

const PREFIX = "splayer.mobile.lyric-match.";

export interface MatchedRecord {
  platformId: string;
  extra?: LyricMatchExtra;
}

export const buildFingerprint = (track: Track): string => {
  const duration = track.duration ? Math.round(track.duration / 5000) : 0;
  return `v2|${normalize(track.title)}|${normalizeTrackArtists(track).join("")}|${duration}`;
};

export const getMatchedId = (fingerprint: string, platform: Platform): MatchedRecord | null => {
  try {
    const raw = readLyricStorage(`${PREFIX}${platform}.${fingerprint}`);
    return raw ? (JSON.parse(raw) as MatchedRecord) : null;
  } catch {
    return null;
  }
};

export const setMatchedId = (
  fingerprint: string,
  platform: Platform,
  platformId: string,
  extra?: LyricMatchExtra,
): void => {
  writeLyricStorage(
    `${PREFIX}${platform}.${fingerprint}`,
    JSON.stringify({ platformId, extra } satisfies MatchedRecord),
  );
};

export const clearLyricMatchCache = (): void => {
  clearLyricStorage(PREFIX);
};
