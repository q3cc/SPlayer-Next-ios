import { z } from "zod/v4";
import type { HostCallMethod } from "@shared/types/plugin";
import type { NowPlayingSnapshot } from "@shared/types/nowPlaying";
import { trackSchema, queueQuerySchema, onlineSearchSchema } from "@shared/utils/musicValidation";
import { omitCredentials } from "@shared/utils/pluginSecurity";

/** 执行已授权的移动端宿主调用；所有参数在接触播放器和平台接口前校验 */
export const dispatchMobilePluginHost = async (
  method: HostCallMethod,
  args: unknown[],
  pluginName: string,
  snapshotProvider?: () => Promise<NowPlayingSnapshot>,
  assertAllowed: () => void = () => {},
): Promise<unknown> => {
  if (method === "api.call") {
    const platform = z.enum(["netease", "qqmusic", "kugou"]).parse(args[0]);
    const name = z.string().min(1).max(256).parse(args[1]);
    const params = z.record(z.string(), z.unknown()).parse(args[2] ?? {});
    for (const key of ["cookie", "domain", "proxy", "headers"]) {
      if (Object.hasOwn(params, key)) throw new Error(`Host API does not accept ${key}`);
    }
    const { mobileProviders } = await import("../providers");
    assertAllowed();
    return omitCredentials(await mobileProviders.call(platform, name, params));
  }
  if (method === "music.searchOnline") {
    const { platform, query, page, limit } = onlineSearchSchema.parse(args[0]);
    const { searchSongs } = await import("@/apis/search");
    assertAllowed();
    const result = await searchSongs(platform, query, (page - 1) * limit, limit);
    return { platform, page, tracks: result.items, total: result.total, hasMore: result.hasMore };
  }
  if (method === "music.searchLibrary") {
    const query = z.string().trim().min(1).max(200).parse(args[0]);
    const limit = z
      .number()
      .int()
      .min(1)
      .max(100)
      .parse(args[1] ?? 20);
    const { mobileLibrary } = await import("../library");
    assertAllowed();
    const result = await mobileLibrary.searchTracks(query);
    if (!result.success || !result.data) throw new Error(result.error);
    return { total: result.data.length, tracks: result.data.slice(0, limit) };
  }
  if (method === "notify") {
    const message = z.string().trim().min(1).max(1000).parse(args[0]);
    const { toast } = await import("@/composables/useToast");
    assertAllowed();
    toast.info(`${pluginName}：${message}`);
    return;
  }
  if (method === "player.getNowPlaying") {
    if (!snapshotProvider) throw new Error("播放器尚未就绪");
    const { lyric, source: _source, ...snapshot } = await snapshotProvider();
    return { ...snapshot, lyricAvailable: lyric.length > 0, lyricLineCount: lyric.length };
  }
  const player = await import("@/core/player");
  assertAllowed();
  switch (method) {
    case "player.play":
      return player.play();
    case "player.pause":
      return player.pause();
    case "player.stop":
      return player.stop();
    case "player.next":
      return player.nextTrack();
    case "player.prev":
      return player.prevTrack();
    case "player.seek":
      return player.seek(z.number().finite().nonnegative().parse(args[0]));
    case "player.setVolume":
      return player.setVolume(z.number().min(0).max(1).parse(args[0]));
    case "player.getPosition": {
      const { mobilePlayer } = await import("../player");
      assertAllowed();
      const status = await mobilePlayer.getStatus();
      if (!status.success || !status.data) throw new Error(status.error);
      return status.data.position;
    }
    case "player.getStatus": {
      const { mobilePlayer } = await import("../player");
      assertAllowed();
      const { useStatusStore } = await import("@/stores/status");
      assertAllowed();
      const result = await mobilePlayer.getStatus();
      if (!result.success || !result.data) throw new Error(result.error);
      const status = useStatusStore();
      const data = result.data;
      return {
        state: data.state,
        positionMs: data.position,
        durationMs: data.duration,
        volume: data.volume,
        isFinished: data.isFinished,
        currentIndex: status.currentIndex,
        repeat: status.repeatMode,
        shuffle: status.shuffleMode,
      };
    }
    case "player.getQueue": {
      const { offset, limit } = queueQuerySchema.parse(args[0] ?? {});
      const { queueEntries } = await import("@/stores/queue");
      assertAllowed();
      const { useStatusStore } = await import("@/stores/status");
      assertAllowed();
      return {
        tracks: queueEntries.value.slice(offset, offset + limit).map((entry) => entry.track),
        total: queueEntries.value.length,
        currentIndex: useStatusStore().currentIndex,
        offset,
      };
    }
    case "player.playTrack": {
      const track = trackSchema.parse(args[0]);
      await player.playNow(track);
      return { id: track.id, source: track.source };
    }
    case "player.addToQueue": {
      const tracks = z.array(trackSchema).min(1).max(50).parse(args[0]);
      const position = z.enum(["next", "end"]).parse(args[1] ?? "next");
      player.insertManyToQueue(tracks, position);
      return { count: tracks.length };
    }
    case "player.setPlayMode": {
      const mode = z
        .strictObject({
          repeat: z.enum(["list", "one"]).optional(),
          shuffle: z.enum(["on", "off"]).optional(),
        })
        .refine((value) => value.repeat || value.shuffle, "Empty play mode")
        .parse(args[0]);
      if (mode.repeat) player.setRepeatMode(mode.repeat);
      if (mode.shuffle) player.setShuffleMode(mode.shuffle);
      return;
    }
    default:
      throw new Error(`未知插件操作：${method}`);
  }
};
