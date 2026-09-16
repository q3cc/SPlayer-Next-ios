import type { Track } from "@shared/types/player";
import type { FavoriteEventInput, PlayEventInput, StatsApi } from "@shared/types/stats";
import { mobileLibrary } from "./library";

const MAX_EVENTS = 5000;
const PLAY_KEY = "splayer.mobile.stats.plays";
const FAVORITE_KEY = "splayer.mobile.stats.favorites";

const read = <T>(key: string): T[] => {
  try {
    return (JSON.parse(localStorage.getItem(key) ?? "[]") as T[]).slice(-MAX_EVENTS);
  } catch {
    return [];
  }
};

const plays = read<PlayEventInput>(PLAY_KEY);
const favorites = read<FavoriteEventInput & { at: number }>(FAVORITE_KEY);
const save = (): void => {
  plays.splice(0, Math.max(0, plays.length - MAX_EVENTS));
  favorites.splice(0, Math.max(0, favorites.length - MAX_EVENTS));
  for (const [key, events] of [
    [PLAY_KEY, plays],
    [FAVORITE_KEY, favorites],
  ] as const) {
    try {
      localStorage.setItem(key, JSON.stringify(events));
    } catch {
      // 统计落盘失败不能打断播放或收藏，本次会话仍可查看有界记录。
    }
  }
};
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

export const mobileStats: StatsApi = {
  recordPlay: (event) => {
    plays.push(event);
    save();
  },
  recordFavorite: (event) => {
    favorites.push({ ...event, at: Date.now() });
    save();
  },
  getStatsSummary: async () => {
    const now = new Date();
    const today = day(now.getTime());
    const currentWeek = weekStart(now);
    const previousWeek = currentWeek - 7 * 86400000;
    const week = plays.filter((item) => item.startedAt >= currentWeek);
    const lastWeek = plays.filter(
      (item) => item.startedAt >= previousWeek && item.startedAt < currentWeek,
    );
    const uniqueDays = [...new Set(plays.map((item) => day(item.startedAt)))].sort().reverse();
    let streakDays = 0;
    let cursor = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const daySet = new Set(uniqueDays);
    while (daySet.has(day(cursor))) {
      streakDays++;
      cursor -= 86400000;
    }
    return {
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
  getTopTracks: async (limit) => topTracks(limit),
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
    const output = new Map<string, number>();
    for (let index = days - 1; index >= 0; index--)
      output.set(day(Date.now() - index * 86400000), 0);
    plays.forEach((item) => {
      const key = day(item.startedAt);
      if (output.has(key)) output.set(key, (output.get(key) ?? 0) + 1);
    });
    return [...output].map(([date, playCount]) => ({ day: date, playCount }));
  },
  getPlayHistoryHourly: async () =>
    Array.from({ length: 24 }, (_, hour) => ({
      hour,
      playCount: plays.filter((item) => new Date(item.startedAt).getHours() === hour).length,
    })),
  getTopAlbums: async (limit) => {
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
