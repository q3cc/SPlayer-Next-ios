import type { Track } from "@shared/types/player";
import type { FavoriteEventInput, PlayEventInput, StatsApi } from "@shared/types/stats";
import localforage from "localforage";
import { mobileLibrary } from "./library";

const MAX_EVENTS = 5000;
const PLAY_KEY = "splayer.mobile.stats.plays";
const FAVORITE_KEY = "splayer.mobile.stats.favorites";
const storage = localforage.createInstance({ name: "splayer", storeName: "stats" });

const readLegacy = <T>(key: string): T[] => {
  try {
    const value = JSON.parse(localStorage.getItem(key) ?? "[]") as unknown;
    return Array.isArray(value) ? (value as T[]).slice(-MAX_EVENTS) : [];
  } catch {
    return [];
  }
};

type StoredFavorite = FavoriteEventInput & { at: number };

let plays: PlayEventInput[] = [];
let favorites: StoredFavorite[] = [];
let pendingPlays: PlayEventInput[] = [];
let pendingFavorites: StoredFavorite[] = [];
let initialized = false;
let initialization: Promise<void> | undefined;
let persistence = Promise.resolve();

/** 原地限制事件数量，避免统计历史无限占用内存。 */
const trim = <T>(events: T[]): T[] => {
  events.splice(0, Math.max(0, events.length - MAX_EVENTS));
  return events;
};

/** 串行保存快照，避免较早的异步写入覆盖新记录。 */
const persist = (): void => {
  const playSnapshot = structuredClone(plays);
  const favoriteSnapshot = structuredClone(favorites);
  persistence = persistence
    .then(async () => {
      await Promise.all([
        storage.setItem("plays", playSnapshot),
        storage.setItem("favorites", favoriteSnapshot),
      ]);
    })
    .catch((error) => console.warn("[stats] 移动端统计保存失败", error));
};

/**
 * 从 IndexedDB 恢复统计，并迁移旧 localStorage 数据。
 * 初始化期间产生的新事件会在恢复后追加，避免冷启动竞态丢记录。
 */
const initialize = (): Promise<void> => {
  initialization ??= (async () => {
    const legacyPlays = readLegacy<PlayEventInput>(PLAY_KEY);
    const legacyFavorites = readLegacy<StoredFavorite>(FAVORITE_KEY);
    try {
      const [storedPlays, storedFavorites] = await Promise.all([
        storage.getItem<PlayEventInput[]>("plays"),
        storage.getItem<StoredFavorite[]>("favorites"),
      ]);
      const startupPlays = pendingPlays;
      const startupFavorites = pendingFavorites;
      pendingPlays = [];
      pendingFavorites = [];
      plays = trim([...(storedPlays ?? legacyPlays), ...startupPlays]);
      favorites = trim([...(storedFavorites ?? legacyFavorites), ...startupFavorites]);
      const shouldMigrate =
        (!storedPlays && legacyPlays.length > 0) ||
        (!storedFavorites && legacyFavorites.length > 0);
      if (shouldMigrate || plays.length > 0 || favorites.length > 0) {
        await Promise.all([
          storage.setItem("plays", structuredClone(plays)),
          storage.setItem("favorites", structuredClone(favorites)),
        ]);
      }
      if (shouldMigrate) {
        localStorage.removeItem(PLAY_KEY);
        localStorage.removeItem(FAVORITE_KEY);
      }
      plays = trim([...plays, ...pendingPlays]);
      favorites = trim([...favorites, ...pendingFavorites]);
      const hasLateEvents = pendingPlays.length > 0 || pendingFavorites.length > 0;
      pendingPlays = [];
      pendingFavorites = [];
      initialized = true;
      if (hasLateEvents) persist();
    } catch (error) {
      plays = trim([...(plays.length ? plays : legacyPlays), ...pendingPlays]);
      favorites = trim([...(favorites.length ? favorites : legacyFavorites), ...pendingFavorites]);
      initialized = true;
      pendingPlays = [];
      pendingFavorites = [];
      console.warn("[stats] 移动端统计恢复失败，改用本次会话数据", error);
    }
  })();
  return initialization;
};

void initialize();

const day = (time: number): string => new Date(time).toLocaleDateString("en-CA");
const weekStart = (date: Date): number => {
  const value = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  value.setDate(value.getDate() - ((value.getDay() + 6) % 7));
  return value.getTime();
};
const topTracks = (limit: number) => {
  const groups = new Map<string, { track: Track; playCount: number }>();
  for (const item of plays) {
    const key = `${item.track.source}:${item.track.id}`;
    const current = groups.get(key) ?? { track: item.track, playCount: 0 };
    current.playCount++;
    groups.set(key, current);
  }
  return [...groups.values()].sort((a, b) => b.playCount - a.playCount).slice(0, limit);
};

/** 按来源与 ID 去重，保留最后一次播放时的完整元数据。 */
const uniquePlayedTracks = (): Track[] => {
  const tracks = new Map<string, Track>();
  plays.forEach((item) => tracks.set(`${item.track.source}:${item.track.id}`, item.track));
  return [...tracks.values()];
};

export const mobileStats: StatsApi = {
  recordPlay: (event) => {
    if (!initialized) {
      pendingPlays.push(event);
      trim(pendingPlays);
      return;
    }
    plays.push(event);
    trim(plays);
    persist();
  },
  recordFavorite: (event) => {
    const stored = { ...event, at: Date.now() };
    if (!initialized) {
      pendingFavorites.push(stored);
      trim(pendingFavorites);
      return;
    }
    favorites.push(stored);
    trim(favorites);
    persist();
  },
  getStatsSummary: async () => {
    await initialize();
    const now = new Date();
    const today = day(now.getTime());
    const currentWeek = weekStart(now);
    const previousWeek = currentWeek - 7 * 86400000;
    const week = plays.filter((item) => item.startedAt >= currentWeek);
    const lastWeek = plays.filter(
      (item) => item.startedAt >= previousWeek && item.startedAt < currentWeek,
    );
    const uniqueDays = [...new Set(plays.map((item) => day(item.startedAt)))].sort().reverse();
    const tracks = uniquePlayedTracks();
    const albums = new Set<string>();
    const artists = new Set<string>();
    const codecs = new Map<string, number>();
    tracks.forEach((track) => {
      if (track.album?.name) {
        albums.add(`${track.source}:${track.album.id ?? track.album.name.toLocaleLowerCase()}`);
      }
      track.artists.forEach((artist) =>
        artists.add(`${track.source}:${artist.id ?? artist.name.toLocaleLowerCase()}`),
      );
      const codec = track.quality?.codec.trim().toLocaleLowerCase();
      if (codec) codecs.set(codec, (codecs.get(codec) ?? 0) + 1);
    });
    let streakDays = 0;
    let cursor = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const daySet = new Set(uniqueDays);
    while (daySet.has(day(cursor))) {
      streakDays++;
      cursor -= 86400000;
    }
    return {
      uniqueTrackCount: tracks.length,
      uniqueAlbumCount: albums.size,
      uniqueArtistCount: artists.size,
      codecs: [...codecs]
        .map(([codec, count]) => ({ codec, count }))
        .sort((a, b) => b.count - a.count || a.codec.localeCompare(b.codec)),
      todayListenedMs: plays
        .filter((item) => day(item.startedAt) === today)
        .reduce((sum, item) => sum + item.listenedMs, 0),
      weekListenedMs: week.reduce((sum, item) => sum + item.listenedMs, 0),
      lastWeekListenedMs: lastWeek.reduce((sum, item) => sum + item.listenedMs, 0),
      totalListenedMs: plays.reduce((sum, item) => sum + item.listenedMs, 0),
      weekPlayCount: week.length,
      totalPlayCount: plays.length,
      weekFavoriteAdds: favorites.filter((item) => item.at >= currentWeek && item.action === "add")
        .length,
      streakDays,
    };
  },
  getTopTracks: async (limit) => {
    await initialize();
    return topTracks(limit);
  },
  getLibraryStats: async () => {
    const result = await mobileLibrary.getTracks();
    const tracks = result.data ?? [];
    const codecs = new Map<string, number>();
    tracks.forEach((track) =>
      codecs.set(
        track.quality?.codec ?? "unknown",
        (codecs.get(track.quality?.codec ?? "unknown") ?? 0) + 1,
      ),
    );
    return {
      trackCount: tracks.length,
      albumCount: new Set(tracks.map((track) => track.album?.name).filter(Boolean)).size,
      artistCount: new Set(tracks.flatMap((track) => track.artists.map((artist) => artist.name)))
        .size,
      totalDurationMs: tracks.reduce((sum, track) => sum + track.duration, 0),
      totalFileSize: tracks.reduce((sum, track) => sum + (track.fileSize ?? 0), 0),
      codecs: [...codecs]
        .map(([codec, count]) => ({ codec, count }))
        .sort((a, b) => b.count - a.count),
    };
  },
  getPlayHistoryDaily: async (days) => {
    await initialize();
    const output = new Map<string, number>();
    for (let index = days - 1; index >= 0; index--)
      output.set(day(Date.now() - index * 86400000), 0);
    plays.forEach((item) => {
      const key = day(item.startedAt);
      if (output.has(key)) output.set(key, (output.get(key) ?? 0) + 1);
    });
    return [...output].map(([date, playCount]) => ({ day: date, playCount }));
  },
  getPlayHistoryHourly: async () => {
    await initialize();
    return Array.from({ length: 24 }, (_, hour) => ({
      hour,
      playCount: plays.filter((item) => new Date(item.startedAt).getHours() === hour).length,
    }));
  },
  getTopAlbums: async (limit) => {
    await initialize();
    const groups = new Map<string, { track: Track; playCount: number }>();
    plays.forEach((item) => {
      const key = item.track.album?.name ?? "Unknown Album";
      const current = groups.get(key) ?? { track: item.track, playCount: 0 };
      current.playCount++;
      groups.set(key, current);
    });
    return [...groups.values()].sort((a, b) => b.playCount - a.playCount).slice(0, limit);
  },
  getTopArtists: async (limit) => {
    await initialize();
    const groups = new Map<
      string,
      { artist: Track["artists"][number]; track: Track; playCount: number }
    >();
    plays.forEach((item) => {
      item.track.artists.forEach((artist) => {
        const current = groups.get(artist.name) ?? { artist, track: item.track, playCount: 0 };
        current.playCount++;
        groups.set(artist.name, current);
      });
    });
    return [...groups.values()].sort((a, b) => b.playCount - a.playCount).slice(0, limit);
  },
};
