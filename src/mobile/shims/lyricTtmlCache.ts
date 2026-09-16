import { clearLyricStorage, readLyricStorage, writeLyricStorage } from "./lyricStorage";
export type Platform = "netease" | "qqmusic";

const PREFIX = "splayer.mobile.ttml.";

export const getCachedTTML = (platform: Platform, id: string): string | null | "miss" => {
  const raw = readLyricStorage(`${PREFIX}${platform}.${id}`);
  if (raw == null) return "miss";
  return raw === "__none__" ? null : raw;
};

export const setCachedTTML = (platform: Platform, id: string, content: string | null): void => {
  writeLyricStorage(`${PREFIX}${platform}.${id}`, content ?? "__none__");
};

export const clearLyricTtmlCache = (): void => {
  clearLyricStorage(PREFIX);
};
