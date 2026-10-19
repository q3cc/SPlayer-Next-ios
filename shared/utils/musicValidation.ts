import { z } from "zod/v4";
import type { Track } from "@shared/types/player";

/** 校验播放必需字段，保留路径、平台附加 ID 等 Track 信息 */
export const trackSchema = z
  .looseObject({
    id: z.string().min(1),
    source: z.enum(["local", "streaming", "plugin", "netease", "qqmusic", "kugou"]),
    plugin: z
      .object({
        pluginId: z.string().min(1),
        source: z.string().min(1),
        musicInfo: z.looseObject({ id: z.string().min(1), name: z.string() }),
      })
      .optional(),
    title: z.string(),
    artists: z.array(z.looseObject({ name: z.string() })),
    duration: z.number().finite().nonnegative(),
  })
  .refine((track) => track.source !== "plugin" || track.plugin !== undefined, {
    message: "Plugin tracks require their source metadata",
    path: ["plugin"],
  }) satisfies z.ZodType<Track>;

export const queueQuerySchema = z.strictObject({
  offset: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).default(0),
  limit: z.number().int().min(1).max(100).default(50),
});

export const onlineSearchSchema = z.strictObject({
  platform: z.enum(["netease", "qqmusic", "kugou"]),
  query: z.string().trim().min(1).max(200),
  page: z.number().int().min(1).max(100).default(1),
  limit: z.number().int().min(1).max(50).default(20),
});
