import { z } from "zod/v4";
import type { Track } from "@shared/types/player";
import type { PluginSearchArgs, PluginSearchResult, ActionIO } from "@shared/types/plugin";
export const pluginSearchSchema = z.strictObject({
  pluginId: z.string().min(1).max(256),
  source: z.string().min(1).max(128),
  keyword: z.string().trim().min(1).max(200),
  page: z.number().int().min(1).max(1000).default(1),
  limit: z.number().int().min(1).max(50).default(20),
});

const candidateSchema = z.looseObject({
  id: z.string().min(1).max(512),
  name: z.string().trim().min(1).max(512),
  singer: z.string().max(1024).optional(),
  album: z.string().max(1024).optional(),
  durationMs: z.number().finite().nonnegative().optional(),
  cover: z.string().max(2048).optional(),
});

/** 将插件候选校验为可安全持久化的曲目，保留来源和分页语义 */
export const normalizePluginSearch = (
  args: Required<PluginSearchArgs>,
  result: ActionIO["musicSearch"]["res"],
): PluginSearchResult => {
  const { pluginId, source, page, limit } = args;
  if (!Array.isArray(result?.list)) throw new Error("Invalid plugin search result");

  const items: Track[] = [];
  const seen = new Set<string>();
  for (const candidate of result.list.slice(0, limit)) {
    try {
      // 队列会保留取数参数，限制单曲大小，避免把完整接口响应一并持久化。
      const serialized = JSON.stringify(candidate);
      if (!serialized || new TextEncoder().encode(serialized).length > 8192) continue;
      const parsed = candidateSchema.safeParse(JSON.parse(serialized));
      if (!parsed.success || seen.has(parsed.data.id)) continue;
      const musicInfo = parsed.data;
      seen.add(musicInfo.id);
      items.push({
        id: `plugin:${[pluginId, source, musicInfo.id].map(encodeURIComponent).join(":")}`,
        source: "plugin",
        plugin: { pluginId, source, musicInfo },
        title: musicInfo.name,
        artists: musicInfo.singer ? [{ name: musicInfo.singer }] : [],
        album: musicInfo.album ? { name: musicInfo.album } : undefined,
        duration: musicInfo.durationMs ?? 0,
        cover: musicInfo.cover,
      });
    } catch {
      // 不可序列化的候选无法在重启后恢复，忽略该条结果。
    }
  }
  const offset = (page - 1) * limit;
  const reportedTotal =
    Number.isSafeInteger(result.total) && result.total! >= 0 ? result.total! : undefined;
  const total = reportedTotal ?? offset + items.length;
  const hasMore =
    typeof result.hasMore === "boolean"
      ? result.hasMore
      : reportedTotal !== undefined
        ? page * limit < total
        : result.list.length >= limit;
  return { items, total, hasMore };
};
