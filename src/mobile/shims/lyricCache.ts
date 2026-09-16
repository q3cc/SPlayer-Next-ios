import { clearLyricStorage, readLyricStorage, writeLyricStorage } from "./lyricStorage";
import type { LyricMatchResult } from "@shared/types/lyrics";
import type { Platform } from "@shared/types/platform";

const PREFIX = "splayer.mobile.lyric.";

export const getCachedLyric = (platform: Platform, id: string): LyricMatchResult | null => {
  try {
    const raw = readLyricStorage(`${PREFIX}${platform}.${id}`);
    return raw ? (JSON.parse(raw) as LyricMatchResult) : null;
  } catch {
    return null;
  }
};

export const setCachedLyric = (platform: Platform, id: string, value: LyricMatchResult): void => {
  writeLyricStorage(`${PREFIX}${platform}.${id}`, JSON.stringify(value));
};

export const clearLyricCache = (): void => {
  clearLyricStorage(PREFIX);
};
