import { z } from "zod/v4";
import type { Track } from "@shared/types/player";
import type { Platform } from "@shared/types/platform";

const recent = new Map<string, Track>();
const remember = (tracks: Track[]): void => {
  for (const track of tracks) {
    recent.delete(track.id);
    recent.set(track.id, track);
    if (recent.size > 200) recent.delete(recent.keys().next().value!);
  }
};
const publicTrack = (track: Track) => ({
  id: track.id,
  title: track.title,
  artists: track.artists,
  album: track.album,
  duration: track.duration,
  source: track.source,
});

export const controlTools = {
  search_online_songs: {
    description: "搜索在线歌曲，返回可用于播放的歌曲 ID",
    readOnly: true,
    schema: z.object({
      platform: z.enum(["netease", "qqmusic", "kugou"]),
      query: z.string().trim().min(1).max(200),
      page: z.number().int().min(1).max(100).default(1),
      limit: z.number().int().min(1).max(50).default(20),
    }),
    run: async (input: { platform: Platform; query: string; page: number; limit: number }) => {
      const { searchSongs } = await import("@/apis/search");
      const result = await searchSongs(
        input.platform,
        input.query,
        (input.page - 1) * input.limit,
        input.limit,
      );
      remember(result.items);
      return {
        total: result.total,
        hasMore: result.hasMore,
        tracks: result.items.map(publicTrack),
      };
    },
  },
  get_playback_status: {
    description: "获取播放状态，时间单位为毫秒",
    schema: z.object({}),
    readOnly: true,
    run: async () => {
      const { useStatusStore } = await import("@/stores/status");
      const status = useStatusStore();
      return {
        state: status.state,
        position: status.position,
        duration: status.duration,
        volume: status.volume,
      };
    },
  },
  get_now_playing: {
    description: "获取当前歌曲",
    schema: z.object({}),
    readOnly: true,
    run: async () => {
      const { useMediaStore } = await import("@/stores/media");
      const track = useMediaStore().track;
      return track ? publicTrack(track) : null;
    },
  },
  play: {
    description: "继续播放",
    schema: z.object({}),
    run: async () => (await import("@/core/player")).play(),
  },
  pause: {
    description: "暂停播放",
    schema: z.object({}),
    run: async () => (await import("@/core/player")).pause(),
  },
  stop: {
    description: "停止播放",
    schema: z.object({}),
    run: async () => (await import("@/core/player")).stop(),
  },
  next_track: {
    description: "下一首",
    schema: z.object({}),
    run: async () => (await import("@/core/player")).nextTrack(),
  },
  previous_track: {
    description: "上一首",
    schema: z.object({}),
    run: async () => (await import("@/core/player")).prevTrack(),
  },
  seek: {
    description: "跳转到指定毫秒位置",
    schema: z.object({ positionMs: z.number().finite().min(0) }),
    run: async (input: { positionMs: number }) =>
      (await import("@/core/player")).seek(input.positionMs),
  },
  set_volume: {
    description: "设置音量，范围 0 到 1",
    schema: z.object({ volume: z.number().finite().min(0).max(1) }),
    run: async (input: { volume: number }) =>
      (await import("@/core/player")).setVolume(input.volume),
  },
  search_library: {
    description: "搜索本地曲库",
    readOnly: true,
    schema: z.object({
      query: z.string().trim().min(1).max(200),
      limit: z.number().int().min(1).max(100).default(20),
    }),
    run: async (input: { query: string; limit: number }) => {
      const result = await window.api.library.searchTracks(input.query);
      if (!result.success) throw new Error(result.error);
      const tracks = (result.data ?? []).slice(0, input.limit);
      remember(tracks);
      return { tracks: tracks.map(publicTrack) };
    },
  },
  play_track: {
    description: "播放本地曲目 ID 或最近搜索到的歌曲 ID，不接受任意文件路径",
    schema: z.object({ trackId: z.string().min(1).max(256) }),
    run: async (input: { trackId: string }) => {
      const result = await window.api.library.getTracksByIds([input.trackId]);
      const track = result.data?.[0] ?? recent.get(input.trackId);
      if (!track) throw new Error("未找到曲目，请先搜索曲库");
      await (await import("@/core/player")).playNow(track);
      return { ok: true };
    },
  },
};

/** 所有入口共用参数校验，不把外部输入当作任意播放器方法调用。 */
export const runControlTool = async (name: string, input: unknown): Promise<unknown> => {
  if (!Object.hasOwn(controlTools, name)) throw new Error("未知控制操作");
  const tool = controlTools[name as keyof typeof controlTools];
  const parsed = tool.schema.parse(input);
  return (await (tool.run as (value: unknown) => Promise<unknown>)(parsed)) ?? { ok: true };
};
